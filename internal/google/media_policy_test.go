package google

import (
	"testing"

	"local/GoogleMessagingAppMac/internal/archive"
)

func TestContactMediaSelectionAndExtension(t *testing.T) {
	for _, a := range []archive.Attachment{
		{MIME: "text/x-vCard"}, // Seen on the paired phone, including nameless cards.
		{MIME: "Text/VCard; charset=UTF-8"},
		{MIME: "application/vcard"},
		{MIME: "application/x-vcard"},
		{MIME: "application/octet-stream", Name: "Shared Contact.VCF"},
	} {
		a.Size = 128
		for _, mode := range []string{"contacts", "photos-and-contacts", "all"} {
			if !a.IncludedIn(mode) || !needsMediaReference(a, mode, 1024) {
				t.Errorf("contact excluded from %s: %q", mode, a.MIME)
			}
		}
		if a.IncludedIn("photos") || a.IncludedIn("none") || mediaExtension(a) != ".vcf" {
			t.Fatalf("incorrect vCard selection/extension: %q", a.MIME)
		}
	}
	photo := archive.Attachment{MIME: "Image/JPEG; charset=binary"}
	if photo.IncludedIn("contacts") || !photo.IncludedIn("photos-and-contacts") || mediaExtension(photo) != ".jpg" {
		t.Fatal("photo filter or normalized extension regressed")
	}
	for _, a := range []archive.Attachment{{MIME: "audio/amr"}, {MIME: "application/pdf"}, {Name: "card.vcf.exe"}} {
		if a.IncludedIn("contacts") || a.IncludedIn("photos-and-contacts") || a.IncludedIn("unknown-mode") {
			t.Fatal("downloaded an unselected attachment")
		}
	}
}

func TestContactReferenceRecoveryRetainsTextAndSkipsOtherMedia(t *testing.T) {
	saved := archive.Message{ID: "card", Body: "local snapshot", Attachments: []archive.Attachment{
		{ID: "vcard", MIME: "text/x-vCard", State: "excluded_by_media_filter", Size: 128},
		{ID: "audio", MIME: "audio/amr", Size: 128},
	}}
	fresh := archive.Message{ID: "card", Body: "newer text", Attachments: []archive.Attachment{
		{ID: "vcard", MIME: "text/x-vcard", MediaID: "original-card", Key: []byte{1}, Size: 130},
		{ID: "audio", MIME: "audio/amr", MediaID: "original-audio", Key: []byte{2}, Size: 128},
	}}
	if mergeMediaReferences(&saved, fresh, "photos-and-contacts", 1024) != 1 || saved.Body != "local snapshot" ||
		saved.Attachments[0].State != "pending" || saved.Attachments[0].MediaID != "original-card" || saved.Attachments[1].MediaID != "" {
		t.Fatal("contact recovery lost metadata or changed unselected content")
	}
	if needsMediaReference(archive.Attachment{MIME: "text/vcard", Size: 2048}, "contacts", 1024) {
		t.Fatal("contact reference lookup ignored budget")
	}
}
