package archive

import (
	"encoding/json"
	"fmt"
	"github.com/google/uuid"
	"os"
	"path/filepath"
	"strconv"
	"time"
)

type Settings struct {
	HistorySince  string `json:"history_since"`
	RetentionDays int    `json:"retention_days"`
}

func ReadSettings(directory string) (Settings, error) {
	var settings Settings
	data, err := os.ReadFile(filepath.Join(directory, "settings.json"))
	if os.IsNotExist(err) {
		return settings, nil
	}
	if err != nil {
		return settings, err
	}
	if len(data) > 4096 || json.Unmarshal(data, &settings) != nil {
		return settings, fmt.Errorf("invalid archive settings")
	}
	if settings.HistorySince != "" {
		date, err := time.Parse("2006-01-02", settings.HistorySince)
		if err != nil || date.Year() < 2000 || date.After(time.Now().Add(24*time.Hour)) {
			return settings, fmt.Errorf("invalid history start date")
		}
	}
	if settings.RetentionDays < 0 || settings.RetentionDays > 36500 {
		return settings, fmt.Errorf("invalid retention window")
	}
	return settings, nil
}

func (s Settings) Cutoff(fallback, now time.Time) time.Time {
	cutoff := fallback
	if date, err := time.Parse("2006-01-02", s.HistorySince); err == nil {
		cutoff = date
	}
	if s.RetentionDays > 0 {
		retention := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC).AddDate(0, 0, -s.RetentionDays)
		if retention.After(cutoff) {
			cutoff = retention
		}
	}
	return cutoff
}

// Only the archive writer performs retention. Message deletion and its file-GC
// queue commit atomically, so a crash cannot leave untracked private media.
func (s *Store) PruneBefore(cutoff time.Time) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err = tx.Exec(`INSERT INTO metadata VALUES('active_retention_floor',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value`, strconv.FormatInt(cutoff.UnixMicro(), 10)); err != nil {
		return err
	}
	eligible := `m.timestamp < ? AND m.id NOT IN (SELECT remote_id FROM outbox WHERE state IN ('preparing','sending','accepted','unknown')) AND m.id NOT IN (SELECT coalesce(json_extract(c.payload,'$.message_id'),'') FROM outbox_commands c JOIN outbox o ON o.id=c.id WHERE o.state IN ('preparing','sending','accepted','unknown'))`
	_, err = tx.Exec(`INSERT OR IGNORE INTO media_gc(path) SELECT json_extract(a.value,'$.path') FROM messages m,json_each(m.payload,'$.attachments') a WHERE `+eligible+` AND json_extract(a.value,'$.path') IS NOT NULL`, cutoff.UnixMicro())
	if err != nil {
		return err
	}
	if _, err = tx.Exec(`DELETE FROM messages AS m WHERE `+eligible, cutoff.UnixMicro()); err != nil {
		return err
	}
	if _, err = tx.Exec(`DELETE FROM arrivals WHERE message_id NOT IN (SELECT id FROM messages)`); err != nil {
		return err
	}
	if _, err = tx.Exec(`UPDATE outbox SET body='' WHERE state IN ('confirmed','applied') AND created<?`, cutoff.UnixMicro()); err != nil {
		return err
	}
	if _, err = tx.Exec(`INSERT OR IGNORE INTO media_gc(path) SELECT 'drafts/attachments/' || json_extract(f.value,'$.id') FROM outbox_commands c JOIN outbox o ON o.id=c.id,json_each(c.payload,'$.files') f WHERE o.state IN ('confirmed','applied') AND o.created<?`, cutoff.UnixMicro()); err != nil {
		return err
	}
	if _, err = tx.Exec(`DELETE FROM outbox_commands WHERE id IN (SELECT id FROM outbox WHERE state IN ('confirmed','applied') AND created<?)`, cutoff.UnixMicro()); err != nil {
		return err
	}
	// Reset only historical coverage whose bytes were removed, so disabling
	// cleanup or moving the start earlier can fetch those pages again.
	if _, err = tx.Exec(`DELETE FROM metadata WHERE key LIKE 'history_coverage:%'`); err != nil {
		return err
	}
	if _, err = tx.Exec(`INSERT INTO metadata VALUES('retention_floor',?) ON CONFLICT(key) DO UPDATE SET value=max(value,excluded.value)`, cutoff.Format("2006-01-02")); err != nil {
		return err
	}
	if err = tx.Commit(); err != nil {
		return err
	}
	return s.CollectMedia()
}

func (s *Store) CollectMedia() error {
	rows, err := s.db.Query(`SELECT path FROM media_gc`)
	if err != nil {
		return err
	}
	var paths []string
	for rows.Next() {
		var path string
		if err = rows.Scan(&path); err != nil {
			rows.Close()
			return err
		}
		paths = append(paths, path)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return err
	}
	root, err := os.OpenRoot(s.Dir)
	if err != nil {
		return err
	}
	defer root.Close()
	var drafts map[string]struct {
		Files []OutgoingFile `json:"files"`
	}
	if data, err := root.ReadFile("drafts/drafts.json"); err == nil {
		if json.Unmarshal(data, &drafts) != nil {
			return fmt.Errorf("draft references could not be read for cleanup")
		}
	} else if !os.IsNotExist(err) {
		return err
	}
	for _, path := range paths {
		var referenced int
		if err = s.db.QueryRow(`SELECT EXISTS(SELECT 1 FROM messages m,json_each(m.payload,'$.attachments') a WHERE json_extract(a.value,'$.path')=?)`, path).Scan(&referenced); err != nil {
			return err
		}
		// Never unlink anything outside the media directory, including files in
		// a tampered archive. Root also rejects symlink escapes.
		allowed := filepath.Dir(path) == "media" && filepath.Base(path) != "."
		if filepath.Dir(path) == "drafts/attachments" {
			id := filepath.Base(path)
			_, validID := uuid.Parse(id)
			allowed = validID == nil && len(id) == 36
			if err = s.db.QueryRow(`SELECT EXISTS(SELECT 1 FROM outbox_commands c,json_each(c.payload,'$.files') f WHERE json_extract(f.value,'$.id')=?)`, id).Scan(&referenced); err != nil {
				return err
			}
			for _, draft := range drafts {
				for _, file := range draft.Files {
					if file.ID == id {
						referenced = 1
					}
				}
			}
		}
		if referenced == 0 && allowed {
			if err = root.Remove(path); err != nil && !os.IsNotExist(err) {
				return err
			}
		}
		if referenced != 0 {
			continue
		}
		if _, err = s.db.Exec(`DELETE FROM media_gc WHERE path=?`, path); err != nil {
			return err
		}
	}
	return nil
}
