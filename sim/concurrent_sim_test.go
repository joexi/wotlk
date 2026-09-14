package sim

import (
	"testing"

	"github.com/wowsims/wotlk/sim/core"
	"github.com/wowsims/wotlk/sim/core/proto"
	googleProto "google.golang.org/protobuf/proto"
)

func totalPlayerCasts(result *proto.RaidSimResult) int32 {
	var casts int32
	for _, party := range result.RaidMetrics.Parties {
		for _, player := range party.Players {
			for _, action := range player.Actions {
				for _, target := range action.Targets {
					casts += target.Casts
				}
			}
		}
	}
	return casts
}

// The concurrent runner must produce the same per-iteration results as the
// serial runner; it only changes how they are aggregated. Every iteration uses
// the same RNG seed in both paths, so integer metrics (casts, hist buckets)
// must match exactly and float aggregates up to summation order.
func TestConcurrentRaidSimMatchesSerial(t *testing.T) {
	makeRequest := func() *proto.RaidSimRequest {
		rsr := googleProto.Clone(makeBenchmarkRaidSimRequest()).(*proto.RaidSimRequest)
		rsr.Encounter.Duration = 120
		rsr.SimOptions = &proto.SimOptions{
			Iterations: 200,
			RandomSeed: 12345,
			IsTest:     false,
		}
		return rsr
	}

	serial := core.RunRaidSim(makeRequest())
	if serial.ErrorResult != "" {
		t.Fatalf("serial sim failed: %s", serial.ErrorResult)
	}
	concurrent := core.RunConcurrentRaidSim(makeRequest())
	if concurrent.ErrorResult != "" {
		t.Fatalf("concurrent sim failed: %s", concurrent.ErrorResult)
	}

	sDps, cDps := serial.RaidMetrics.Dps, concurrent.RaidMetrics.Dps

	const tolerance = 0.05
	if diff := sDps.Avg - cDps.Avg; diff > tolerance || diff < -tolerance {
		t.Errorf("avg dps mismatch: serial %f vs concurrent %f", sDps.Avg, cDps.Avg)
	}
	if sDps.Max != cDps.Max {
		t.Errorf("max dps mismatch: serial %f vs concurrent %f", sDps.Max, cDps.Max)
	}
	if sDps.Min != cDps.Min {
		t.Errorf("min dps mismatch: serial %f vs concurrent %f", sDps.Min, cDps.Min)
	}
	if stdevDiff := sDps.Stdev - cDps.Stdev; stdevDiff > tolerance || stdevDiff < -tolerance {
		t.Errorf("dps stdev mismatch: serial %f vs concurrent %f", sDps.Stdev, cDps.Stdev)
	}

	if len(sDps.Hist) != len(cDps.Hist) {
		t.Errorf("dps hist size mismatch: serial %d vs concurrent %d", len(sDps.Hist), len(cDps.Hist))
	} else {
		for bucket, count := range sDps.Hist {
			if cDps.Hist[bucket] != count {
				t.Errorf("dps hist bucket %d mismatch: serial %d vs concurrent %d", bucket, count, cDps.Hist[bucket])
			}
		}
	}

	if sCasts, cCasts := totalPlayerCasts(serial), totalPlayerCasts(concurrent); sCasts != cCasts {
		t.Errorf("total casts mismatch: serial %d vs concurrent %d", sCasts, cCasts)
	}

	for p, party := range serial.RaidMetrics.Parties {
		for q, player := range party.Players {
			cPlayer := concurrent.RaidMetrics.Parties[p].Players[q]
			if diff := player.Dps.Avg - cPlayer.Dps.Avg; diff > tolerance || diff < -tolerance {
				t.Errorf("player %s avg dps mismatch: serial %f vs concurrent %f", player.Name, player.Dps.Avg, cPlayer.Dps.Avg)
			}
		}
	}
}

// One op = a full 1000-iteration raid sim request processed serially, i.e.
// what the Simulate button cost before concurrency.
func BenchmarkSimulateFullRequestSerial(b *testing.B) {
	rsr := makeBenchmarkRaidSimRequest()
	rsr.Encounter.Duration = core.LongDuration
	rsr.SimOptions.IsTest = false
	rsr.SimOptions.Iterations = 1000
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		result := core.RunRaidSim(rsr)
		if result.ErrorResult != "" {
			b.Fatalf("BenchmarkSimulateFullRequestSerial failed: %v", result.ErrorResult)
		}
	}
}

// One op = the same full 1000-iteration raid sim request processed by the
// concurrent runner, i.e. what the Simulate button costs now.
func BenchmarkSimulateFullRequestConcurrent(b *testing.B) {
	rsr := makeBenchmarkRaidSimRequest()
	rsr.Encounter.Duration = core.LongDuration
	rsr.SimOptions.IsTest = false
	rsr.SimOptions.Iterations = 1000
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		result := core.RunConcurrentRaidSim(rsr)
		if result.ErrorResult != "" {
			b.Fatalf("BenchmarkSimulateFullRequestConcurrent failed: %v", result.ErrorResult)
		}
	}
}
