package main

import (
	"context"
	"encoding/json"
	"log"
	"net/http"
	"os"
	"time"

	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"
)

func main() {
	port := envOr("PORT", "8080")

	// Subcomando `healthcheck`: usado pelo HEALTHCHECK do compose. Como
	// a imagem é `FROM scratch` (sem shell/curl/wget), o próprio binário
	// é quem testa o /health. Exit 0 = ok, 1 = degraded.
	if len(os.Args) > 1 && os.Args[1] == "healthcheck" {
		resp, err := http.Get("http://127.0.0.1:" + port + "/health")
		if err != nil || resp.StatusCode != http.StatusOK {
			os.Exit(1)
		}
		os.Exit(0)
	}

	databaseURL := envOr("DATABASE_URL", "mongodb://root:root@database:27017")
	internalToken := envOr("INTERNAL_TOKEN", "dev-shared-secret")

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	client, err := mongo.Connect(ctx, options.Client().ApplyURI(databaseURL))
	if err != nil {
		log.Fatalf("mongo connect: %v", err)
	}
	if err := client.Ping(ctx, nil); err != nil {
		log.Fatalf("mongo ping: %v", err)
	}
	counters := client.Database("demo").Collection("counters")
	log.Println("connected to mongo")

	mux := http.NewServeMux()

	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		err := client.Ping(r.Context(), nil)
		status := "ok"
		if err != nil {
			status = "degraded"
		}
		writeJSON(w, map[string]any{"service": "backend", "db": status})
	})

	mux.HandleFunc("/counter", requireInternal(internalToken, func(w http.ResponseWriter, r *http.Request) {
		filter := bson.M{"_id": "global"}

		if r.Method == http.MethodPost {
			_, err := counters.UpdateOne(
				r.Context(),
				filter,
				bson.M{"$inc": bson.M{"value": 1}},
				options.Update().SetUpsert(true),
			)
			if err != nil {
				http.Error(w, err.Error(), http.StatusInternalServerError)
				return
			}
		}

		var doc struct {
			Value int `bson:"value"`
		}
		if err := counters.FindOne(r.Context(), filter).Decode(&doc); err != nil && err != mongo.ErrNoDocuments {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}

		writeJSON(w, map[string]any{
			"service": "backend",
			"global":  doc.Value,
		})
	}))

	log.Printf("backend listening on :%s", port)
	log.Fatal(http.ListenAndServe(":"+port, mux))
}

func requireInternal(token string, next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("X-Internal-Token") != token {
			http.Error(w, `{"error":"unauthorized: missing or invalid X-Internal-Token"}`, http.StatusUnauthorized)
			return
		}
		next(w, r)
	}
}

func writeJSON(w http.ResponseWriter, body any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(body)
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
