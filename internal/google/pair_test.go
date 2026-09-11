package google

import (
	"context"
	"errors"
	"testing"

	"local/GoogleMessagingAppMac/internal/archive"
)

func TestNewAccountPairingNeverReusesAnExistingArchive(t *testing.T) {
	for _, scenario := range []string{"new", "duplicate", "cancelled", "identity_changed", "save_failed"} {
		t.Run(scenario, func(t *testing.T) {
			store, err := archive.Open(t.TempDir())
			if err != nil {
				t.Fatal(err)
			}
			defer store.Close()
			original, _ := identityFromAuth(testAuth())
			candidate := original
			candidate.Account = identityHash("account", "second@example.test")
			if scenario == "duplicate" {
				candidate = original
			}
			account := "second@example.test"
			if scenario == "duplicate" {
				account = "person@example.test"
			}
			finished, saves := 0, 0
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			steps := relinkSteps{
				login:   func(context.Context) error { return nil },
				account: func(context.Context) (string, error) { return account, nil },
				start:   func(context.Context) (string, archive.PairingIdentity, error) { return "🐢", candidate, nil },
				finish: func(context.Context) (archive.PairingIdentity, error) {
					finished++
					if scenario == "cancelled" {
						cancel()
					}
					if scenario == "identity_changed" {
						return original, nil
					}
					return candidate, nil
				},
				save: func(context.Context) error {
					saves++
					if scenario == "save_failed" {
						return errors.New("private helper response")
					}
					return nil
				},
			}
			err = performPair(ctx, store, []archive.PairingIdentity{original}, steps, func(PairingStatus) {})
			if scenario == "new" {
				if err != nil || saves != 1 {
					t.Fatal("new pairing failed")
				}
			} else if err == nil {
				t.Fatal("unsafe pairing succeeded")
			}
			if scenario == "duplicate" && (!errors.Is(err, ErrAccountAlreadyAdded) || finished != 0 || saves != 0) {
				t.Fatal("duplicate reached confirmation or save")
			}
			identity, e := store.PairingIdentity()
			if e != nil {
				t.Fatal(e)
			}
			if scenario == "new" || scenario == "save_failed" {
				if identity != candidate {
					t.Fatal("new archive not bound to verified candidate")
				}
			} else if identity.Valid() || saves != 0 {
				t.Fatal("rejected pairing mutated archive or credentials")
			}
			if scenario == "save_failed" && !errors.Is(err, ErrPairingSave) {
				t.Fatal("raw save error exposed")
			}
		})
	}
}
