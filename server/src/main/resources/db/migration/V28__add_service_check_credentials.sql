ALTER TABLE service_checks
    ADD COLUMN IF NOT EXISTS credential_ciphertext VARCHAR(1000);
