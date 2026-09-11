package google

import (
	"context"
	"errors"
	"fmt"
	"os/exec"

	"local/GoogleMessagingAppMac/internal/archive"
)

var ErrAccountAlreadyAdded = errors.New("this account and phone already have a saved archive; switch to that account")

func PairWithStatus(ctx context.Context, store *archive.Store, known []archive.PairingIdentity, emit func(PairingStatus)) error {
	stats, err := store.Stats()
	if err != nil {
		return err
	}
	if stats.Messages > 0 || stats.Conversations > 0 {
		return errors.New("use relink for an archive containing history")
	}
	identity, err := store.PairingIdentity()
	if err != nil {
		return err
	}
	if identity.Valid() {
		if err = rejectDuplicate(identity, known); err != nil {
			return err
		}
		// A cancelled or uncertain first setup retains its directory and identity.
		// Retry through verification rather than replacing it with another account.
		return Relink(ctx, store, emit)
	}
	c, err := newClient(store.Dir)
	if err != nil {
		return err
	}
	probe := exec.CommandContext(ctx, c.helper, "has", c.account)
	err = probe.Run()
	if err == nil {
		return ErrOriginalIdentityMissing
	}
	exitErr, ok := err.(*exec.ExitError)
	if !ok || exitErr.ExitCode() != 3 {
		return fmt.Errorf("could not check existing Keychain pairing")
	}
	defer c.Close()
	pairCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	return performPair(ctx, store, known, c.pairingSteps(pairCtx), emit)
}

func rejectDuplicate(candidate archive.PairingIdentity, known []archive.PairingIdentity) error {
	for _, identity := range known {
		if identity.Valid() && candidate == identity {
			return ErrAccountAlreadyAdded
		}
	}
	return nil
}

func performPair(ctx context.Context, store *archive.Store, known []archive.PairingIdentity, steps relinkSteps, emit func(PairingStatus)) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	emit(PairingStatus{State: "signing_in"})
	if err := steps.login(ctx); err != nil {
		return err
	}
	emit(PairingStatus{State: "verifying_account"})
	account, err := steps.account(ctx)
	if err != nil {
		return err
	}
	if account == "" {
		return ErrOriginalIdentityMissing
	}
	emoji, proposed, err := steps.start(ctx)
	if err != nil {
		return err
	}
	if !proposed.Valid() || proposed.Account != identityHash("account", account) {
		return ErrAccountMismatch
	}
	if err = rejectDuplicate(proposed, known); err != nil {
		return err
	}
	if err = ctx.Err(); err != nil {
		return err
	}
	emit(PairingStatus{State: "waiting_for_phone", Emoji: emoji})
	candidate, err := steps.finish(ctx)
	if err != nil {
		return err
	}
	if err = compareIdentity(proposed, candidate); err != nil {
		return err
	}
	emit(PairingStatus{State: "verifying_pairing"})
	// Also checks cancellation and persists identity before touching Keychain.
	return commitRelink(ctx, store, proposed, candidate, steps.save)
}
