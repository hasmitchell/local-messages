package live

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"time"

	"local/GoogleMessagingAppMac/internal/archive"
)

// Contact photos are optional decoration: a failed lookup never ends the
// session, and each inventory pass checks a bounded number of people.
const (
	avatarBatchLimit    = 40
	avatarRequestSize   = 10
	avatarRefreshPeriod = 7 * 24 * time.Hour
	avatarByteLimit     = 1 << 20
)

type avatarSource interface {
	ParticipantThumbnails(context.Context, []string) (map[string][]byte, error)
}

func refreshAvatars(ctx context.Context, store *archive.Store, client any, limit int) error {
	src, ok := client.(avatarSource)
	if !ok {
		return nil
	}
	people, err := store.ContactParticipants()
	if err != nil {
		return err
	}
	known, err := store.Avatars()
	if err != nil {
		return err
	}
	var due []string
	for _, p := range people {
		if record, exists := known[p.ID]; !exists || time.Since(record.Updated) > avatarRefreshPeriod {
			due = append(due, p.ID)
		}
	}
	if len(due) == 0 {
		return nil
	}
	if len(due) > limit {
		due = due[:limit]
	}
	dir := filepath.Join(store.Dir, "media", "avatars")
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	for start := 0; start < len(due); start += avatarRequestSize {
		end := min(start+avatarRequestSize, len(due))
		photos, err := src.ParticipantThumbnails(ctx, due[start:end])
		if err != nil {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			return nil
		}
		for _, id := range due[start:end] {
			record := archive.AvatarRecord{ParticipantID: id, Updated: time.Now().UTC()}
			data := photos[id]
			if ext := imageExtension(data); ext != "" && len(data) <= avatarByteLimit {
				sum := sha256.Sum256(data)
				record.Hash = hex.EncodeToString(sum[:])
				fileKey := sha256.Sum256([]byte(id))
				name := hex.EncodeToString(fileKey[:16]) + ext
				record.Path = filepath.Join("media", "avatars", name)
				if previous := known[id]; previous.Hash != record.Hash || previous.Path != record.Path {
					if err := writePrivateFile(dir, name, data); err != nil {
						return err
					}
				}
			} else if previous := known[id]; previous.Path != "" {
				// The contact no longer has a photo; drop the stale file.
				_ = os.Remove(filepath.Join(store.Dir, previous.Path))
			}
			if err := store.PutAvatar(record); err != nil {
				return err
			}
		}
	}
	return nil
}

func writePrivateFile(dir, name string, data []byte) error {
	temp, err := os.CreateTemp(dir, ".avatar-")
	if err != nil {
		return err
	}
	tempName := temp.Name()
	if _, err = temp.Write(data); err != nil {
		temp.Close()
		os.Remove(tempName)
		return err
	}
	if err = temp.Chmod(0600); err != nil {
		temp.Close()
		os.Remove(tempName)
		return err
	}
	if err = temp.Close(); err != nil {
		os.Remove(tempName)
		return err
	}
	return os.Rename(tempName, filepath.Join(dir, name))
}

// Only image formats macOS can decode are saved; anything else is treated as no photo.
func imageExtension(data []byte) string {
	switch {
	case bytes.HasPrefix(data, []byte{0xFF, 0xD8, 0xFF}):
		return ".jpg"
	case bytes.HasPrefix(data, []byte{0x89, 'P', 'N', 'G'}):
		return ".png"
	case len(data) >= 12 && bytes.Equal(data[:4], []byte("RIFF")) && bytes.Equal(data[8:12], []byte("WEBP")):
		return ".webp"
	default:
		return ""
	}
}
