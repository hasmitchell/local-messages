package archive

import "time"

// Contact is a phone address-book entry as Google Messages reports it.
type Contact struct {
	ParticipantID string `json:"participant_id"`
	Name          string `json:"name"`
	Number        string `json:"number"`
	ContactID     string `json:"contact_id,omitempty"`
}

// PutContacts replaces the saved address-book snapshot.
func (s *Store) PutContacts(contacts []Contact) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err = tx.Exec(`DELETE FROM contacts`); err != nil {
		return err
	}
	now := time.Now().UnixMicro()
	for _, c := range contacts {
		if c.ParticipantID == "" || (c.Name == "" && c.Number == "") {
			continue
		}
		if _, err = tx.Exec(`INSERT OR REPLACE INTO contacts(participant_id,name,number,contact_id,updated) VALUES(?,?,?,?,?)`, c.ParticipantID, c.Name, c.Number, c.ContactID, now); err != nil {
			return err
		}
	}
	if err = tx.Commit(); err != nil {
		return err
	}
	return s.SetMeta("contacts_refreshed", time.Now().UTC().Format(time.RFC3339))
}

func (s *Store) ContactsRefreshedAt() (time.Time, error) {
	value, err := s.Meta("contacts_refreshed")
	if err != nil || value == "" {
		return time.Time{}, err
	}
	return time.Parse(time.RFC3339, value)
}
