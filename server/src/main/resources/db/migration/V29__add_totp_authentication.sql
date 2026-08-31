ALTER TABLE app_users ADD COLUMN totp_secret_ciphertext TEXT;
ALTER TABLE app_users ADD COLUMN totp_enabled BOOLEAN NOT NULL DEFAULT FALSE;
