package archive

import (
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

// AdoptSentOriginals keeps the files uploaded from this Mac as the local
// originals of their confirmed messages. The phone's record of an outgoing
// MMS often carries no download reference, so without this the attachment
// would read "Not saved on this Mac" while its bytes sit in the staging folder.
// Returns how many attachments were adopted.
func (s *Store) AdoptSentOriginals() (int, error) {
	rows, err := s.db.Query(`SELECT o.remote_id,c.payload FROM outbox o JOIN outbox_commands c ON c.id=o.id
        WHERE o.state='confirmed' AND o.remote_id!='' AND o.conversation_id!='' AND json_array_length(c.payload,'$.files')>0`)
	if err != nil {
		return 0, err
	}
	type sent struct {
		messageID string
		command   SendCommand
	}
	var sends []sent
	for rows.Next() {
		var messageID string
		var data []byte
		if err = rows.Scan(&messageID, &data); err != nil {
			rows.Close()
			return 0, err
		}
		var command SendCommand
		if json.Unmarshal(data, &command) != nil || !command.Valid() || command.Kind != "send_text" {
			continue
		}
		sends = append(sends, sent{messageID, command})
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return 0, err
	}
	adopted := 0
	for _, item := range sends {
		m, err := s.MessageByID(item.messageID)
		if err == sql.ErrNoRows {
			continue
		}
		if err != nil {
			return adopted, err
		}
		if m.ConversationID != item.command.ConversationID || !m.Outgoing {
			continue
		}
		pairs := pairSentFiles(m.Attachments, item.command.Files)
		changed := false
		for i, j := range pairs {
			a := &m.Attachments[i]
			if a.State == "downloaded_original" {
				if _, statErr := os.Stat(filepath.Join(s.Dir, a.Path)); statErr == nil {
					continue
				}
			}
			ok, err := s.keepSentFile(m.ID, a, item.command.Files[j])
			if err != nil {
				return adopted, err
			}
			if ok {
				changed = true
				adopted++
			}
		}
		if changed {
			if err = s.UpdateMedia(m); err != nil {
				return adopted, err
			}
		}
	}
	return adopted, nil
}

// pairSentFiles matches a message's attachments to the files that were
// uploaded for it. Only an unambiguous match is used: the same count in the
// same order, or a single attachment for a single file. Media types must agree
// unless the phone reported none.
func pairSentFiles(attachments []Attachment, files []OutgoingFile) map[int]int {
	pairs := map[int]int{}
	if len(files) == 0 || (len(attachments) != len(files) && (len(attachments) != 1 || len(files) != 1)) {
		return pairs
	}
	for i, a := range attachments {
		if compatibleSentType(a, files[i]) {
			pairs[i] = i
		}
	}
	return pairs
}

func compatibleSentType(a Attachment, file OutgoingFile) bool {
	reported := a.MediaType()
	switch reported {
	case "", "image/unknown", "application/octet-stream":
		return true
	}
	staged := (Attachment{MIME: file.MIME}).MediaType()
	reportedKind, _, _ := strings.Cut(reported, "/")
	stagedKind, _, _ := strings.Cut(staged, "/")
	return reportedKind == stagedKind
}

// keepSentFile copies one staged upload into the media folder after checking
// it is still the file that was sent. A missing or altered staged file is not
// an error: the attachment simply stays as the phone reported it.
func (s *Store) keepSentFile(messageID string, a *Attachment, file OutgoingFile) (bool, error) {
	if file.Size <= 0 || file.Size > MaxUploadBytes {
		return false, nil
	}
	// Reads stay inside the staging folder, including through symlinks.
	archiveRoot, err := filepath.EvalSymlinks(s.Dir)
	if err != nil {
		return false, nil
	}
	staging := filepath.Join(archiveRoot, "drafts", "attachments")
	resolved, err := filepath.EvalSymlinks(staging)
	if err != nil || resolved != staging {
		return false, nil
	}
	root, err := os.OpenRoot(staging)
	if err != nil {
		return false, nil
	}
	defer root.Close()
	source, err := root.Open(file.ID)
	if err != nil {
		return false, nil
	}
	defer source.Close()
	stat, err := source.Stat()
	if err != nil || !stat.Mode().IsRegular() || stat.Size() != file.Size {
		return false, nil
	}
	dir := filepath.Join(s.Dir, "media")
	if err = os.MkdirAll(dir, 0700); err != nil {
		return false, err
	}
	kept := *a
	kept.MIME = file.MIME
	hash := sha256.Sum256([]byte(messageID + "\x00" + a.ID + "\x00sent:" + file.ID))
	name := hex.EncodeToString(hash[:]) + kept.Extension()
	temp, err := os.CreateTemp(dir, ".sent-")
	if err != nil {
		return false, err
	}
	tempName := temp.Name()
	digest := sha256.New()
	copied, err := io.Copy(io.MultiWriter(temp, digest), io.LimitReader(source, file.Size+1))
	if err == nil {
		err = temp.Sync()
	}
	if closeErr := temp.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		os.Remove(tempName)
		return false, err
	}
	if copied != file.Size || hex.EncodeToString(digest.Sum(nil)) != strings.ToLower(file.SHA256) {
		os.Remove(tempName)
		return false, nil
	}
	if err = os.Rename(tempName, filepath.Join(dir, name)); err != nil {
		os.Remove(tempName)
		return false, fmt.Errorf("keeping sent attachment: %w", err)
	}
	a.MIME = file.MIME
	a.Size = file.Size
	a.Path = filepath.Join("media", name)
	a.State = "downloaded_original"
	a.Source = "sent"
	a.Attempts, a.NextAttempt = 0, 0
	return true, nil
}
