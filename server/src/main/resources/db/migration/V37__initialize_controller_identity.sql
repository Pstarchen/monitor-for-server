INSERT INTO system_settings (setting_key, setting_value)
VALUES ('controller.id', gen_random_uuid()::text)
ON CONFLICT (setting_key) DO NOTHING;
