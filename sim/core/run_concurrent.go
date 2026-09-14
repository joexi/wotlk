package core

import (
	"math"
	"runtime"
	"runtime/debug"
	"time"

	"github.com/wowsims/wotlk/sim/core/proto"
	googleProto "google.golang.org/protobuf/proto"
)

// Minimum number of iterations per worker; splitting finer than this just
// wastes time re-constructing environments.
const minIterationsPerConcurrentWorker = 32

// Returns how many parallel sims a request should be split into. Returns 1
// whenever the request must run serially to keep its current semantics.
func concurrentSimWorkerCount(request *proto.RaidSimRequest) int32 {
	opts := request.SimOptions
	if opts == nil {
		return 1
	}
	// IsTest requires the deterministic per-label RNG streams of a single sim.
	// Debug collects logs from every iteration in order. Interactive mode needs
	// user input between steps.
	if opts.IsTest || opts.Debug || opts.Interactive {
		return 1
	}
	// With health-based fight ends, iterations use state from earlier
	// iterations to estimate the fight duration, so they aren't independent.
	if request.Encounter != nil && request.Encounter.UseHealth {
		return 1
	}

	numWorkers := min(int32(runtime.GOMAXPROCS(0)), opts.Iterations/minIterationsPerConcurrentWorker)
	return max(1, numWorkers)
}

// Runs the raid sim splitting the iterations across all available CPU cores,
// then combines the partial results. Each iteration uses the same RNG seed it
// would have used in a serial run, so the per-iteration results are identical;
// only the float64 aggregation order differs.
//
// Requests that can't be split (tests, debug runs, health-based encounters,
// single-core machines like wasm) fall back to the serial runner.
func RunConcurrentRaidSim(request *proto.RaidSimRequest) *proto.RaidSimResult {
	return runConcurrentSim(request, nil)
}

func RunConcurrentRaidSimAsync(request *proto.RaidSimRequest, progress chan *proto.ProgressMetrics) {
	go runConcurrentSim(request, progress)
}

func runConcurrentSim(request *proto.RaidSimRequest, progress chan *proto.ProgressMetrics) (result *proto.RaidSimResult) {
	numWorkers := concurrentSimWorkerCount(request)
	if numWorkers <= 1 {
		return runSim(request, progress, false)
	}

	defer func() {
		if err := recover(); err != nil {
			errStr := ""
			switch errt := err.(type) {
			case string:
				errStr = errt
			case error:
				errStr = errt.Error()
			}
			errStr += "\nStack Trace:\n" + string(debug.Stack())
			result = &proto.RaidSimResult{ErrorResult: errStr}
			if progress != nil {
				progress <- &proto.ProgressMetrics{FinalRaidResult: result}
			}
		}
		if progress != nil {
			close(progress)
		}
	}()

	totalIterations := request.SimOptions.Iterations
	baseSeed := request.SimOptions.RandomSeed
	if baseSeed == 0 {
		baseSeed = time.Now().UnixNano()
	}

	type workerUpdate struct {
		idx int
		pm  *proto.ProgressMetrics
	}
	updates := make(chan workerUpdate, numWorkers*4)

	chunkIterations := make([]int32, numWorkers)
	results := make([]*proto.RaidSimResult, numWorkers)

	var iterOffset int32
	for i := int32(0); i < numWorkers; i++ {
		n := totalIterations / numWorkers
		if i < totalIterations%numWorkers {
			n++
		}
		chunkIterations[i] = n

		req := googleProto.Clone(request).(*proto.RaidSimRequest)
		req.SimOptions.Iterations = n
		// Each worker's iteration seeds continue where the previous worker's
		// end, matching the seed sequence of a serial run.
		req.SimOptions.RandomSeed = baseSeed + int64(iterOffset)
		if i > 0 {
			// Only the first chunk runs the globally-first iteration.
			req.SimOptions.DebugFirstIteration = false
		}
		iterOffset += n

		workerProgress := make(chan *proto.ProgressMetrics, 16)
		go runSim(req, workerProgress, false)
		go func(idx int) {
			for pm := range workerProgress {
				updates <- workerUpdate{idx: idx, pm: pm}
			}
			updates <- workerUpdate{idx: idx, pm: nil}
		}(int(i))
	}

	completedIterations := make([]int32, numWorkers)
	dpsValues := make([]float64, numWorkers)
	hpsValues := make([]float64, numWorkers)
	runningWorkers := int(numWorkers)
	lastReport := time.Now()
	for runningWorkers > 0 {
		update := <-updates
		if update.pm == nil {
			runningWorkers--
			continue
		}

		if update.pm.FinalRaidResult != nil {
			results[update.idx] = update.pm.FinalRaidResult
			completedIterations[update.idx] = chunkIterations[update.idx]
		} else if update.pm.CompletedIterations > 0 {
			completedIterations[update.idx] = update.pm.CompletedIterations
			dpsValues[update.idx] = update.pm.Dps
			hpsValues[update.idx] = update.pm.Hps
		}

		if progress != nil && time.Since(lastReport) > time.Millisecond*100 {
			var doneIterations int32
			var dpsSum, hpsSum float64
			for i := range completedIterations {
				doneIterations += completedIterations[i]
				dpsSum += dpsValues[i] * float64(completedIterations[i])
				hpsSum += hpsValues[i] * float64(completedIterations[i])
			}
			if doneIterations > 0 {
				progress <- &proto.ProgressMetrics{
					TotalIterations:     totalIterations,
					CompletedIterations: doneIterations,
					Dps:                 dpsSum / float64(doneIterations),
					Hps:                 hpsSum / float64(doneIterations),
				}
			}
			lastReport = time.Now()
		}
	}

	for _, res := range results {
		if res == nil {
			panic("Missing result from concurrent sim worker")
		}
		if res.ErrorResult != "" {
			if progress != nil {
				progress <- &proto.ProgressMetrics{FinalRaidResult: res}
			}
			return res
		}
	}

	result = combineConcurrentSimResults(results, chunkIterations)

	if progress != nil {
		progress <- &proto.ProgressMetrics{
			TotalIterations:     totalIterations,
			CompletedIterations: totalIterations,
			Dps:                 result.RaidMetrics.Dps.Avg,
			Hps:                 result.RaidMetrics.Hps.Avg,
			FinalRaidResult:     result,
		}
	}
	return result
}

// Merges the partial results of the concurrent workers into results[0], which
// is returned. chunk 0 keeps its Logs and FirstIterationDuration, which cover
// the globally-first iteration.
func combineConcurrentSimResults(results []*proto.RaidSimResult, iterations []int32) *proto.RaidSimResult {
	combined := results[0]
	n := iterations[0]
	for i := 1; i < len(results); i++ {
		src := results[i]
		srcN := iterations[i]

		combined.AvgIterationDuration = weightedAvg(combined.AvgIterationDuration, src.AvgIterationDuration, n, srcN)
		mergeRaidMetrics(combined.RaidMetrics, src.RaidMetrics, n, srcN)
		mergeEncounterMetrics(combined.EncounterMetrics, src.EncounterMetrics, n, srcN)

		n += srcN
	}
	return combined
}

func weightedAvg(dst, src float64, dstN, srcN int32) float64 {
	return (dst*float64(dstN) + src*float64(srcN)) / float64(dstN+srcN)
}

func mergeRaidMetrics(dst, src *proto.RaidMetrics, dstN, srcN int32) {
	dst.Dps = mergeDistributionMetrics(dst.Dps, src.Dps, dstN, srcN)
	dst.Hps = mergeDistributionMetrics(dst.Hps, src.Hps, dstN, srcN)
	for i, party := range dst.Parties {
		srcParty := src.Parties[i]
		party.Dps = mergeDistributionMetrics(party.Dps, srcParty.Dps, dstN, srcN)
		party.Hps = mergeDistributionMetrics(party.Hps, srcParty.Hps, dstN, srcN)
		for j, player := range party.Players {
			mergeUnitMetrics(player, srcParty.Players[j], dstN, srcN)
		}
	}
}

func mergeEncounterMetrics(dst, src *proto.EncounterMetrics, dstN, srcN int32) {
	if dst == nil || src == nil {
		return
	}
	for i, target := range dst.Targets {
		mergeUnitMetrics(target, src.Targets[i], dstN, srcN)
	}
}

func mergeUnitMetrics(dst, src *proto.UnitMetrics, dstN, srcN int32) {
	if dst == nil || src == nil {
		return
	}

	dst.Dps = mergeDistributionMetrics(dst.Dps, src.Dps, dstN, srcN)
	dst.Dpasp = mergeDistributionMetrics(dst.Dpasp, src.Dpasp, dstN, srcN)
	dst.Threat = mergeDistributionMetrics(dst.Threat, src.Threat, dstN, srcN)
	dst.Dtps = mergeDistributionMetrics(dst.Dtps, src.Dtps, dstN, srcN)
	dst.Tmi = mergeDistributionMetrics(dst.Tmi, src.Tmi, dstN, srcN)
	dst.Hps = mergeDistributionMetrics(dst.Hps, src.Hps, dstN, srcN)
	dst.Tto = mergeDistributionMetrics(dst.Tto, src.Tto, dstN, srcN)

	dst.SecondsOomAvg = weightedAvg(dst.SecondsOomAvg, src.SecondsOomAvg, dstN, srcN)
	dst.ChanceOfDeath = weightedAvg(dst.ChanceOfDeath, src.ChanceOfDeath, dstN, srcN)

	dst.Actions = mergeActionMetricsLists(dst.Actions, src.Actions)
	dst.Auras = mergeAuraMetricsLists(dst.Auras, src.Auras, dstN, srcN)
	dst.Resources = mergeResourceMetricsLists(dst.Resources, src.Resources)

	// Pets are constructed deterministically, so they match up by index.
	for i, pet := range dst.Pets {
		mergeUnitMetrics(pet, src.Pets[i], dstN, srcN)
	}
}

// Merges src into dst (both may be nil) with iteration-count weighting. The
// combined avg/stdev are computed from the exact per-chunk moments, matching
// what a serial run would produce up to float rounding.
func mergeDistributionMetrics(dst, src *proto.DistributionMetrics, dstN, srcN int32) *proto.DistributionMetrics {
	if dst == nil {
		return src
	}
	if src == nil {
		return dst
	}

	dstW := float64(dstN) / float64(dstN+srcN)
	srcW := float64(srcN) / float64(dstN+srcN)

	avg := dst.Avg*dstW + src.Avg*srcW
	// Reconstruct E[x^2] of each chunk from its stdev and mean.
	e2 := (dst.Stdev*dst.Stdev+dst.Avg*dst.Avg)*dstW + (src.Stdev*src.Stdev+src.Avg*src.Avg)*srcW
	dst.Avg = avg
	dst.Stdev = math.Sqrt(max(0, e2-avg*avg))

	if src.Max > dst.Max {
		dst.Max = src.Max
		dst.MaxSeed = src.MaxSeed
	}
	if src.Min < dst.Min {
		dst.Min = src.Min
		dst.MinSeed = src.MinSeed
	}

	if src.Hist != nil {
		if dst.Hist == nil {
			dst.Hist = src.Hist
		} else {
			for k, v := range src.Hist {
				dst.Hist[k] += v
			}
		}
	}

	dst.AllValues = append(dst.AllValues, src.AllValues...)

	return dst
}

type combinedActionKey struct {
	spellId int32
	itemId  int32
	otherId int32
	tag     int32
}

func makeCombinedActionKey(id *proto.ActionID) combinedActionKey {
	key := combinedActionKey{}
	if id != nil {
		key.tag = id.Tag
		switch rawId := id.RawId.(type) {
		case *proto.ActionID_SpellId:
			key.spellId = rawId.SpellId
		case *proto.ActionID_ItemId:
			key.itemId = rawId.ItemId
		case *proto.ActionID_OtherId:
			key.otherId = int32(rawId.OtherId)
		}
	}
	return key
}

// The order of action entries comes from map iteration, so it differs between
// workers; entries are matched by ActionID. Unmatched entries are appended.
func mergeActionMetricsLists(dst, src []*proto.ActionMetrics) []*proto.ActionMetrics {
	index := make(map[combinedActionKey]*proto.ActionMetrics, len(dst))
	for _, am := range dst {
		index[makeCombinedActionKey(am.Id)] = am
	}
	for _, srcAction := range src {
		dstAction, ok := index[makeCombinedActionKey(srcAction.Id)]
		if !ok {
			dst = append(dst, srcAction)
			continue
		}
		for _, srcTarget := range srcAction.Targets {
			var dstTarget *proto.TargetedActionMetrics
			for _, t := range dstAction.Targets {
				if t.UnitIndex == srcTarget.UnitIndex {
					dstTarget = t
					break
				}
			}
			if dstTarget == nil {
				dstAction.Targets = append(dstAction.Targets, srcTarget)
				continue
			}
			dstTarget.Casts += srcTarget.Casts
			dstTarget.Hits += srcTarget.Hits
			dstTarget.Crits += srcTarget.Crits
			dstTarget.Misses += srcTarget.Misses
			dstTarget.Dodges += srcTarget.Dodges
			dstTarget.Parries += srcTarget.Parries
			dstTarget.Blocks += srcTarget.Blocks
			dstTarget.Glances += srcTarget.Glances
			dstTarget.Damage += srcTarget.Damage
			dstTarget.Threat += srcTarget.Threat
			dstTarget.Healing += srcTarget.Healing
			dstTarget.Shielding += srcTarget.Shielding
			dstTarget.CastTimeMs += srcTarget.CastTimeMs
		}
	}
	return dst
}

func mergeAuraMetricsLists(dst, src []*proto.AuraMetrics, dstN, srcN int32) []*proto.AuraMetrics {
	index := make(map[combinedActionKey]*proto.AuraMetrics, len(dst))
	for _, am := range dst {
		index[makeCombinedActionKey(am.Id)] = am
	}
	merged := make(map[combinedActionKey]bool, len(src))
	for _, srcAura := range src {
		key := makeCombinedActionKey(srcAura.Id)
		merged[key] = true
		dstAura, ok := index[key]
		if !ok {
			// Unknown to the chunks merged so far, which observed the aura for
			// 0 uptime/procs across their dstN iterations.
			origAvg := srcAura.UptimeSecondsAvg
			srcAura.UptimeSecondsStdev = combineStdevs(0, 0, srcAura.UptimeSecondsStdev, origAvg, dstN, srcN)
			srcAura.UptimeSecondsAvg = weightedAvg(0, origAvg, dstN, srcN)
			srcAura.ProcsAvg = weightedAvg(0, srcAura.ProcsAvg, dstN, srcN)
			dst = append(dst, srcAura)
			continue
		}
		newUptimeAvg := weightedAvg(dstAura.UptimeSecondsAvg, srcAura.UptimeSecondsAvg, dstN, srcN)
		dstAura.UptimeSecondsStdev = combineStdevs(dstAura.UptimeSecondsStdev, dstAura.UptimeSecondsAvg, srcAura.UptimeSecondsStdev, srcAura.UptimeSecondsAvg, dstN, srcN)
		dstAura.UptimeSecondsAvg = newUptimeAvg
		dstAura.ProcsAvg = weightedAvg(dstAura.ProcsAvg, srcAura.ProcsAvg, dstN, srcN)
	}
	// Entries the src chunk doesn't know observed 0 uptime/procs across its
	// srcN iterations.
	for _, dstAura := range dst {
		key := makeCombinedActionKey(dstAura.Id)
		if !merged[key] && index[key] != nil {
			dstAura.UptimeSecondsStdev = combineStdevs(dstAura.UptimeSecondsStdev, dstAura.UptimeSecondsAvg, 0, 0, dstN, srcN)
			dstAura.UptimeSecondsAvg = weightedAvg(dstAura.UptimeSecondsAvg, 0, dstN, srcN)
			dstAura.ProcsAvg = weightedAvg(dstAura.ProcsAvg, 0, dstN, srcN)
		}
	}
	return dst
}

func combineStdevs(dstStdev, dstAvg, srcStdev, srcAvg float64, dstN, srcN int32) float64 {
	dstW := float64(dstN) / float64(dstN+srcN)
	srcW := float64(srcN) / float64(dstN+srcN)
	avg := dstAvg*dstW + srcAvg*srcW
	e2 := (dstStdev*dstStdev+dstAvg*dstAvg)*dstW + (srcStdev*srcStdev+srcAvg*srcAvg)*srcW
	return math.Sqrt(max(0, e2-avg*avg))
}

type combinedResourceKey struct {
	action combinedActionKey
	kind   proto.ResourceType
}

func mergeResourceMetricsLists(dst, src []*proto.ResourceMetrics) []*proto.ResourceMetrics {
	index := make(map[combinedResourceKey]*proto.ResourceMetrics, len(dst))
	for _, rm := range dst {
		index[combinedResourceKey{action: makeCombinedActionKey(rm.Id), kind: rm.Type}] = rm
	}
	for _, srcRes := range src {
		dstRes, ok := index[combinedResourceKey{action: makeCombinedActionKey(srcRes.Id), kind: srcRes.Type}]
		if !ok {
			dst = append(dst, srcRes)
			continue
		}
		dstRes.Events += srcRes.Events
		dstRes.Gain += srcRes.Gain
		dstRes.ActualGain += srcRes.ActualGain
	}
	return dst
}
