package archive

import "strings"

func (a Attachment) MediaType() string {
	value, _, _ := strings.Cut(a.MIME, ";")
	return strings.ToLower(strings.TrimSpace(value))
}

func (a Attachment) IsContact() bool {
	switch a.MediaType() {
	case "text/vcard", "text/x-vcard", "application/vcard", "application/x-vcard":
		return true
	}
	return strings.HasSuffix(strings.ToLower(a.Name), ".vcf")
}

// Use the same selection policy for reference recovery and byte downloads.
func (a Attachment) IncludedIn(mode string) bool {
	photo := strings.HasPrefix(a.MediaType(), "image/")
	switch mode {
	case "photos":
		return photo
	case "contacts":
		return a.IsContact()
	case "photos-and-contacts":
		return photo || a.IsContact()
	case "all":
		return true
	default:
		return false
	}
}
