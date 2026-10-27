package ranking

import (
	"math"
	"testing"
	"time"
)

var epoch = time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)

func near(a, b float64) bool { return math.Abs(a-b) < 1e-9 }

func TestHotValues(t *testing.T) {
	tests := []struct {
		name       string
		ups, downs int
		at         time.Time
		want       float64
	}{
		{"no votes at epoch", 0, 0, epoch, 0},
		{"+9 at epoch", 9, 0, epoch, 1},
		{"-9 at epoch", 0, 9, epoch, -1},
		{"votes cancel out", 50, 50, epoch, 0},
		// Golden value from the hot_rank() SQL function: Go and SQL must agree.
		{"matches SQL", 120, 20, time.Date(2026, 10, 27, 12, 0, 0, 0, time.UTC), 577.0443213737826},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := Hot(tt.ups, tt.downs, tt.at); !near(got, tt.want) {
				t.Errorf("Hot(%d, %d, %v) = %v, want %v", tt.ups, tt.downs, tt.at, got, tt.want)
			}
		})
	}
}

func TestHotTenfoldScoreEqualsTau(t *testing.T) {
	older := Hot(99, 0, epoch)
	younger := Hot(9, 0, epoch.Add(Tau*time.Second))
	if !near(older, younger) {
		t.Errorf("100 votes now = %v, 10 votes Tau later = %v; want equal", older, younger)
	}
}

func TestHotNewerWinsOnEqualScore(t *testing.T) {
	if Hot(10, 0, epoch) >= Hot(10, 0, epoch.Add(time.Minute)) {
		t.Error("newer post with the same score must rank higher")
	}
}

func TestHotFirstUpvoteCounts(t *testing.T) {
	if Hot(1, 0, epoch) <= Hot(0, 0, epoch) {
		t.Error("the first upvote must raise the rank")
	}
}
