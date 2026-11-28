package server

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"unicode/utf16"
	"unicode/utf8"
)

func readBody(r *http.Request, fields ...string) (map[string]json.RawMessage, error) {
	return readBodySized(r, 65536, fields...)
}

func readBodySized(r *http.Request, limit int64, fields ...string) (map[string]json.RawMessage, error) {
	data, err := io.ReadAll(io.LimitReader(r.Body, limit+1))
	if err != nil || !utf8.Valid(data) {
		return nil, invalid
	}
	if int64(len(data)) > limit {
		return nil, &apiError{413, "request_too_large", "Request body is too large"}
	}
	d := json.NewDecoder(bytes.NewReader(data))
	token, err := d.Token()
	if err != nil || token != json.Delim('{') {
		return nil, invalid
	}
	allowed := make(map[string]bool, len(fields))
	for _, field := range fields {
		allowed[field] = true
	}
	result := make(map[string]json.RawMessage, len(fields))
	for d.More() {
		key, err := d.Token()
		if err != nil {
			return nil, invalid
		}
		name, _ := key.(string)
		if !allowed[name] || result[name] != nil {
			return nil, invalid
		}
		var value json.RawMessage
		if err := d.Decode(&value); err != nil {
			return nil, invalid
		}
		result[name] = value
	}
	if token, err = d.Token(); err != nil || token != json.Delim('}') {
		return nil, invalid
	}
	if _, err = d.Token(); err != io.EOF {
		return nil, invalid
	}
	return result, nil
}

func stringField(fields map[string]json.RawMessage, name string) (string, error) {
	var value *string
	if err := json.Unmarshal(fields[name], &value); err != nil || value == nil {
		return "", invalid
	}
	return *value, nil
}

// Python's existing request and lock keys use ASCII-escaped, compact JSON.
func canonicalJSON(value any) ([]byte, error) {
	var buffer bytes.Buffer
	encoder := json.NewEncoder(&buffer)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(value); err != nil {
		return nil, err
	}
	var ascii bytes.Buffer
	for _, char := range string(bytes.TrimSuffix(buffer.Bytes(), []byte{'\n'})) {
		if char < 127 {
			ascii.WriteByte(byte(char))
		} else if char <= 0xffff {
			_, _ = fmt.Fprintf(&ascii, "\\u%04x", char)
		} else {
			high, low := utf16.EncodeRune(char)
			_, _ = fmt.Fprintf(&ascii, "\\u%04x\\u%04x", high, low)
		}
	}
	return ascii.Bytes(), nil
}

func requestDigest(operation string, payload map[string]any) (string, error) {
	body, err := canonicalJSON([]any{operation, payload})
	if err != nil {
		return "", err
	}
	digest := sha256.Sum256(body)
	return hex.EncodeToString(digest[:]), nil
}

func numberString(value int64) string { return strconv.FormatInt(value, 10) }
