package live

import (
	"context"
	"time"

	"local/GoogleMessagingAppMac/internal/archive"
)

type contactSource interface {
	Contacts(context.Context) ([]archive.Contact, error)
}

// The address book changes rarely; one listing per day keeps New Message's
// picker current without adding to the phone's load.
func refreshContacts(ctx context.Context, store *archive.Store, client any) error {
	src, ok := client.(contactSource)
	if !ok {
		return nil
	}
	last, err := store.ContactsRefreshedAt()
	if err != nil {
		return err
	}
	if time.Since(last) < 24*time.Hour {
		return nil
	}
	contacts, err := src.Contacts(ctx)
	if err != nil {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		return nil
	}
	return store.PutContacts(contacts)
}
