UPDATE system_settings
SET setting_value = '星辰监控'
WHERE setting_key = 'system.site_name'
  AND setting_value IN ('星辰云巡', '观澜监控');

UPDATE system_settings
SET setting_value = '/brand-icon.png'
WHERE setting_key = 'system.site_icon_url'
  AND setting_value = '/favicon.svg';
