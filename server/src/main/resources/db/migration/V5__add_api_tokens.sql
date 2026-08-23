CREATE TABLE api_tokens (
    id BIGSERIAL NOT NULL,
    user_id BIGINT NOT NULL,
    name VARCHAR(128) NOT NULL,
    token_hash VARCHAR(64) NOT NULL,
    token_prefix VARCHAR(20) NOT NULL,
    scopes_json TEXT NOT NULL,
    server_ids_json TEXT NOT NULL,
    expires_at TIMESTAMP(6) WITH TIME ZONE,
    last_used_at TIMESTAMP(6) WITH TIME ZONE,
    last_used_ip VARCHAR(64),
    revoked_at TIMESTAMP(6) WITH TIME ZONE,
    created_at TIMESTAMP(6) WITH TIME ZONE NOT NULL,
    PRIMARY KEY (id),
    CONSTRAINT uq_api_tokens_hash UNIQUE (token_hash),
    CONSTRAINT fk_api_tokens_user FOREIGN KEY (user_id) REFERENCES app_users(id) ON DELETE CASCADE
);
CREATE INDEX idx_api_tokens_user_created ON api_tokens (user_id, created_at);
CREATE INDEX idx_api_tokens_hash ON api_tokens (token_hash);
