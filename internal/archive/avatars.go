package archive

import (
	"encoding/json"
	"time"
)

// AvatarRecord remembers whether a participant's contact photo was fetched.
// An empty Path records a participant without a photo, so the lookup is not
// repeated on every inventory pass.
type AvatarRecord struct {
	ParticipantID string
	Path          string
	Hash          string
	Updated       time.Time
}

func (s *Store) Avatars() (map[string]AvatarRecord, error) {
	rows, err := s.db.Query(`SELECT participant_id,path,hash,updated FROM participant_avatars`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := map[string]AvatarRecord{}
	for rows.Next() {
		var r AvatarRecord
		var updated int64
		if err = rows.Scan(&r.ParticipantID, &r.Path, &r.Hash, &updated); err != nil {
			return nil, err
		}
		r.Updated = time.UnixMicro(updated).UTC()
		result[r.ParticipantID] = r
	}
	return result, rows.Err()
}

func (s *Store) PutAvatar(r AvatarRecord) error {
	_, err := s.db.Exec(`INSERT INTO participant_avatars(participant_id,path,hash,updated) VALUES(?,?,?,?)
		ON CONFLICT(participant_id) DO UPDATE SET path=excluded.path,hash=excluded.hash,updated=excluded.updated`,
		r.ParticipantID, r.Path, r.Hash, r.Updated.UnixMicro())
	return err
}

// ContactParticipants lists the distinct people in saved conversations who are
// linked to a phone contact; only those can have a contact photo.
func (s *Store) ContactParticipants() ([]Participant, error) {
	rows, err := s.db.Query(`SELECT payload FROM conversation_details`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	seen := map[string]bool{}
	var result []Participant
	for rows.Next() {
		var payload []byte
		if err = rows.Scan(&payload); err != nil {
			return nil, err
		}
		var participants []Participant
		if json.Unmarshal(payload, &participants) != nil {
			continue
		}
		for _, p := range participants {
			if p.IsMe || p.ID == "" || p.ContactID == "" || seen[p.ID] {
				continue
			}
			seen[p.ID] = true
			result = append(result, p)
		}
	}
	return result, rows.Err()
}
