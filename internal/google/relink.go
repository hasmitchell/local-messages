package google

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/google/uuid"
	"go.mau.fi/mautrix-gmessages/pkg/libgm"
	"local/GoogleMessagingAppMac/internal/archive"
)

type PairingStatus struct {
	State string `json:"state"`
	Emoji string `json:"emoji,omitempty"`
}

var (
	ErrOriginalIdentityMissing = errors.New("the archive's original account and phone could not be verified")
	ErrAccountMismatch         = errors.New("sign in with the same Google account used for this archive")
	ErrPhoneMismatch           = errors.New("the paired phone differs from this archive's original phone")
	ErrArchiveBusy             = errors.New("this archive is in use by another sync or pairing process")
)

func identityHash(kind, value string) string {
	h := sha256.Sum256([]byte("local-messages/identity/v1/" + kind + "\x00" + value))
	return hex.EncodeToString(h[:])
}

func identityFromAuth(auth *libgm.AuthData) (archive.PairingIdentity, error) {
	if auth == nil || !auth.IsGoogleAccount() || auth.PairingID == uuid.Nil {
		return archive.PairingIdentity{}, ErrOriginalIdentityMissing
	}
	account := strings.ToLower(strings.TrimSpace(auth.Mobile.GetSourceID()))
	if account == "" || auth.DestRegID == uuid.Nil {
		return archive.PairingIdentity{}, ErrOriginalIdentityMissing
	}
	return archive.PairingIdentity{Version: 1, Account: identityHash("account", account), Phone: identityHash("phone", auth.DestRegID.String())}, nil
}

func compareIdentity(expected, candidate archive.PairingIdentity) error {
	if !expected.Valid() || !candidate.Valid() {
		return ErrOriginalIdentityMissing
	}
	if expected.Account != candidate.Account {
		return ErrAccountMismatch
	}
	if expected.Phone != candidate.Phone {
		return ErrPhoneMismatch
	}
	return nil
}

// Prior versions keyed credentials by archive path and disallowed re-pairing.
// That existing credential is the migration anchor; never infer ownership from
// contacts, message text, or the newly selected account.
func originalIdentity(ctx context.Context, store *archive.Store, readSaved func(context.Context) ([]byte, error)) (archive.PairingIdentity, error) {
	identity, err := store.PairingIdentity()
	if err != nil {
		return identity, err
	}
	if identity.Valid() {
		return identity, nil
	}
	data, err := readSaved(ctx)
	if err != nil {
		return identity, ErrOriginalIdentityMissing
	}
	var saved session
	if json.Unmarshal(data, &saved) != nil {
		return identity, ErrOriginalIdentityMissing
	}
	identity, err = identityFromAuth(saved.Auth)
	if err != nil {
		return identity, err
	}
	return identity, store.BindPairingIdentity(identity)
}

// The candidate exists only in memory until verification and phone confirmation.
// No history fetch, media upload, message send or old credential save occurs here.
func Relink(ctx context.Context, store *archive.Store, emit func(PairingStatus)) error {
	c, err := newClient(store.Dir)
	if err != nil {
		return err
	}
	expected, err := originalIdentity(ctx, store, func(ctx context.Context) ([]byte, error) { return c.helperCall(ctx, "get", nil) })
	if err != nil {
		return err
	}
	defer c.Close()
	pairCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	return performRelink(ctx, store, expected, c.pairingSteps(pairCtx), emit)
}

func (c *Client) pairingSteps(pairCtx context.Context) relinkSteps {
	var pairing *libgm.PairingSession
	return relinkSteps{
		login: func(ctx context.Context) error {
			cookies, err := c.helperCall(ctx, "login", nil)
			if err != nil {
				return err
			}
			auth := libgm.NewAuthData()
			if json.Unmarshal(cookies, &auth.Cookies) != nil {
				return errors.New("invalid sign-in session")
			}
			c.configure(auth, nil)
			return nil
		},
		account: func(ctx context.Context) (string, error) {
			if err := c.GM.FetchConfig(ctx); err != nil {
				return "", errors.New("Google account verification failed")
			}
			return strings.ToLower(strings.TrimSpace(c.GM.Config.GetDeviceInfo().GetEmail())), nil
		},
		start: func(ctx context.Context) (string, archive.PairingIdentity, error) {
			emoji, ps, err := c.GM.StartGaiaPairing(ctx, pairCtx)
			if err != nil {
				return "", archive.PairingIdentity{}, errors.New("Google pairing could not start")
			}
			pairing = ps
			// These values come from Google's authenticated device response.
			auth := c.GM.AuthData
			account := strings.ToLower(strings.TrimSpace(auth.Mobile.GetSourceID()))
			if account == "" || auth.DestRegID == uuid.Nil {
				return "", archive.PairingIdentity{}, ErrOriginalIdentityMissing
			}
			return emoji, archive.PairingIdentity{Version: 1, Account: identityHash("account", account), Phone: identityHash("phone", auth.DestRegID.String())}, nil
		},
		finish: func(ctx context.Context) (archive.PairingIdentity, error) {
			if _, err := c.GM.FinishGaiaPairing(ctx, pairing); err != nil {
				return archive.PairingIdentity{}, errors.New("phone confirmation was cancelled, incorrect or expired")
			}
			return identityFromAuth(c.GM.AuthData)
		},
		save: c.Save,
	}
}

type relinkSteps struct {
	login   func(context.Context) error
	account func(context.Context) (string, error)
	start   func(context.Context) (string, archive.PairingIdentity, error)
	finish  func(context.Context) (archive.PairingIdentity, error)
	save    func(context.Context) error
}

func performRelink(ctx context.Context, store *archive.Store, expected archive.PairingIdentity, steps relinkSteps, emit func(PairingStatus)) error {
	if !expected.Valid() {
		return ErrOriginalIdentityMissing
	}
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
	if account == "" || identityHash("account", account) != expected.Account {
		return ErrAccountMismatch
	}
	emoji, proposed, err := steps.start(ctx)
	if err != nil {
		return err
	}
	if err = compareIdentity(expected, proposed); err != nil {
		return err
	}
	emit(PairingStatus{State: "waiting_for_phone", Emoji: emoji})
	candidate, err := steps.finish(ctx)
	if err != nil {
		return err
	}
	emit(PairingStatus{State: "verifying_pairing"})
	return commitRelink(ctx, store, expected, candidate, steps.save)
}

func commitRelink(ctx context.Context, store *archive.Store, expected, candidate archive.PairingIdentity, save func(context.Context) error) error {
	if err := compareIdentity(expected, candidate); err != nil {
		return err
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	if err := store.BindPairingIdentity(candidate); err != nil {
		return err
	}
	if err := store.ResetIncompleteHistory(); err != nil {
		return err
	}
	// Keychain writes replace the value atomically. If the helper result is
	// uncertain, don't restore stale credentials over a possibly committed pairing.
	if err := save(ctx); err != nil {
		return fmt.Errorf("%w", ErrPairingSave)
	}
	return nil
}

var ErrPairingSave = errors.New("the verified pairing could not be saved to Keychain")

func PairingFailureState(err error) string {
	switch {
	case errors.Is(err, context.Canceled):
		return "cancelled"
	case errors.Is(err, context.DeadlineExceeded):
		return "timed_out"
	case errors.Is(err, ErrArchiveBusy):
		return "archive_busy"
	case errors.Is(err, ErrAccountAlreadyAdded):
		return "account_exists"
	case errors.Is(err, ErrAccountMismatch):
		return "wrong_account"
	case errors.Is(err, ErrPhoneMismatch):
		return "wrong_phone"
	case errors.Is(err, ErrOriginalIdentityMissing):
		return "identity_missing"
	case errors.Is(err, archive.ErrIdentityMismatch):
		return "identity_mismatch"
	case errors.Is(err, ErrPairingSave):
		return "keychain_error"
	default:
		return "failed"
	}
}
