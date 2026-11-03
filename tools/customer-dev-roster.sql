\pset format csv
SELECT
  u.id,
  u.created_at::date AS created,
  coalesce(p.first_name,'') AS first_name,
  coalesce(p.last_name,'') AS last_name,
  coalesce(p.email,'') AS email,
  coalesce(p.phone,'') AS phone,
  coalesce(p.age_range,'') AS age_range,
  coalesce(p.gender,'') AS gender,
  coalesce(array_to_string(p.goals,';'),'') AS goals,
  coalesce(array_to_string(p.practices,';'),'') AS practices,
  coalesce(array_to_string(p.devices,';'),'') AS devices,
  p.consent_share_team, p.consent_ai_insights,
  m.first_ts::date AS first_sample, m.last_ts::date AS last_sample, m.days AS sample_days, m.n AS samples,
  a.n AS activities, a.last_act::date AS last_activity,
  e.n AS usage_events, e.last_ev::date AS last_event, e.first_ev::date AS first_event, e.days AS active_days,
  t.n AS tokens
FROM users u
LEFT JOIN profiles p ON p.user_id=u.id
LEFT JOIN (SELECT user_id, min(ts) first_ts, max(ts) last_ts, count(distinct ts::date) days, count(*) n FROM metric_samples GROUP BY user_id) m ON m.user_id=u.id
LEFT JOIN (SELECT user_id, count(*) n, max(started_at) last_act FROM activities GROUP BY user_id) a ON a.user_id=u.id
LEFT JOIN (SELECT user_id, count(*) n, max(ts) last_ev, min(ts) first_ev, count(distinct ts::date) days FROM usage_events GROUP BY user_id) e ON e.user_id=u.id
LEFT JOIN (SELECT user_id, count(*) n FROM api_tokens GROUP BY user_id) t ON t.user_id=u.id
ORDER BY greatest(coalesce(m.last_ts, 'epoch'), coalesce(e.last_ev,'epoch'), coalesce(a.last_act,'epoch')) DESC;
