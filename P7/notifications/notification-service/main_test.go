package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestHealthHandlerReturns200AndStatus(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	rec := httptest.NewRecorder()

	healthHandler(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d", rec.Code)
	}

	var body map[string]string
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("expected valid JSON body, got error: %v", err)
	}
	if body["status"] != "Notification Service is running" {
		t.Fatalf("unexpected status message: %q", body["status"])
	}
}

func TestRootHandlerReturns200(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	rec := httptest.NewRecorder()

	rootHandler(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d", rec.Code)
	}
}

func TestNotificationReqUnmarshalling(t *testing.T) {
	raw := []byte(`{"event":"ORDER_CREATED","order_id":42}`)

	var req NotificationReq
	if err := json.Unmarshal(raw, &req); err != nil {
		t.Fatalf("unexpected error unmarshalling: %v", err)
	}
	if req.Event != "ORDER_CREATED" || req.OrderID != 42 {
		t.Fatalf("unexpected decoded value: %+v", req)
	}
}
