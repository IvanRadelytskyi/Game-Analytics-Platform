WITH user_first_payment AS (
	-- Місяць НАЙПЕРШОГО платежу юзера (основа його когорти)
	SELECT 
		user_id
		,date(date_trunc('month', min(payment_date))) AS first_payment_month
	FROM project.games_payments
	GROUP BY 1
)
, monthly_revenue AS (
	-- Агрегую транзакції до місяців
	SELECT
		date(date_trunc('month', payment_date)) AS payment_month
		,user_id
		,sum(revenue_amount_usd) AS total_revenue
	FROM project.games_payments 
	GROUP BY 1, 2
)
, settlement_month AS (
	-- Будую часові вікна за допомогою LAG/LEAD
	SELECT 
		m.payment_month
		,m.user_id
		,m.total_revenue
		,f.first_payment_month
		,date(m.payment_month - INTERVAL '1 month') AS previous_calendar_month
		,date(m.payment_month + INTERVAL '1 month') AS next_calendar_month
		,lag(m.total_revenue) OVER (PARTITION BY m.user_id ORDER BY m.payment_month) AS previous_paid_month_revenue
		,lag(m.payment_month) OVER (PARTITION BY m.user_id ORDER BY m.payment_month) AS previous_paid_month
		,lead(m.payment_month) OVER (PARTITION BY m.user_id ORDER BY m.payment_month) AS next_paid_month
	FROM monthly_revenue m
	LEFT JOIN user_first_payment f ON m.user_id = f.user_id
)
, churn_month AS (
	-- Визначаю, чи є наступний календарний місяць місяцем відтоку
	SELECT 
		payment_month
		,user_id
		,total_revenue
		,first_payment_month
		,previous_calendar_month
		,next_calendar_month
		,previous_paid_month_revenue
		,previous_paid_month
		,next_paid_month
		,CASE WHEN next_paid_month IS NULL OR next_paid_month != next_calendar_month
				THEN next_calendar_month
		 END AS churn_month
	FROM settlement_month
)
-- Збираю все на рівні ЮЗЕРА за КОЖЕН МІСЯЦЬ
SELECT 
    s.payment_month AS metric_month
    ,s.user_id
    ,s.first_payment_month AS cohort_month
    -- Джойн властивостей користувача для фільтрів у Tableau
    ,up."language" AS "User Language"
    ,up.age AS "User Age"
    ,up.game_name AS "Game Name"
    -- Метрики на рівні юзера
    ,s.total_revenue AS "MRR"
    ,1 AS "Paid Users Count" -- Кожен рядок — це 1 активний платник
    -- New MRR & New Paid Users
    ,CASE WHEN s.previous_paid_month IS NULL THEN s.total_revenue ELSE 0 END AS "New MRR"
    ,CASE WHEN s.previous_paid_month IS NULL THEN 1 ELSE 0 END AS "Is New Paid User"
    -- Expansion & Contraction 
    ,CASE WHEN s.previous_paid_month IS NOT NULL AND s.total_revenue > s.previous_paid_month_revenue 
			THEN s.total_revenue - s.previous_paid_month_revenue ELSE 0 END AS "Expansion MRR"
    ,CASE WHEN s.previous_paid_month IS NOT NULL AND s.total_revenue < s.previous_paid_month_revenue 
			THEN s.total_revenue - s.previous_paid_month_revenue ELSE 0 END AS "Contraction MRR" -- Буде негативним автоматично
    -- Churn 
    ,CASE WHEN s.churn_month = date(s.payment_month + INTERVAL '1 month') THEN 1 ELSE 0 END AS "Churned Users Count"
    ,CASE WHEN s.churn_month = date(s.payment_month + INTERVAL '1 month') THEN -s.total_revenue ELSE 0 END AS "Churned Revenue"
FROM churn_month s
LEFT JOIN project.games_paid_users up ON s.user_id = up.user_id
ORDER BY 1, 2;