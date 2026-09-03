ALTER TABLE devices ADD COLUMN agent_enrollment_token_hash VARCHAR(64);
ALTER TABLE devices ADD COLUMN agent_enrollment_token_expires_at TIMESTAMP WITH TIME ZONE;
