-- Mukuru Technical Assessment
-- Phemelo Sebopelo | March 2026
-- PostgreSQL


-- Base view: clean paid, non-cancelled orders
-- Paid = OrderPaid is a real date (not sentinel 1900/1970/0)
-- Cancelled = OrderCancelled is a real date, so we exclude those

CREATE OR REPLACE VIEW vw_paid_orders AS
SELECT
    OrderID,
    SenderKey,
    PayInValue,
    PayinCountryKey,
    PayoutCountryKey,
    PayInCurrencyKey,
    PayoutCurrencyKey,
    CommissionExchangeRate,
    PayOutPartnerCommission,
    CAST(OrderPaid AS TIMESTAMP)    AS OrderPaid_dt,
    CAST(OrderCreated AS TIMESTAMP) AS OrderCreated_dt,
    DATE_TRUNC('month', CAST(OrderPaid AS TIMESTAMP)) AS OrderMonth,
    TO_CHAR(CAST(OrderPaid AS TIMESTAMP), 'YYYY-MM')  AS YearMonth
FROM Orders
WHERE
    CAST(OrderPaid AS DATE) NOT IN ('1900-01-01', '1970-01-01')
    AND OrderPaid <> '0'
    AND (
        CAST(OrderCancelled AS DATE) IN ('1900-01-01', '1970-01-01')
        OR OrderCancelled = '0'
    );


-- -------------------------------------------------------
-- Q1: Paid Orders, MoM % and YoY % by month
-- Last 13 months (Apr 2012 - Apr 2013)
-- Slicers in Power BI: PayIn Country, PayOut Country, Date
-- -------------------------------------------------------

WITH monthly AS (
    SELECT
        OrderMonth,
        YearMonth,
        COUNT(OrderID) AS PaidOrders
    FROM vw_paid_orders
    GROUP BY OrderMonth, YearMonth
),

-- filter to last 13 months
last_13 AS (
    SELECT *
    FROM monthly
    WHERE OrderMonth >= (
        SELECT DATE_TRUNC('month', MAX(OrderPaid_dt)) - INTERVAL '12 months'
        FROM vw_paid_orders
    )
),

-- MoM: current vs prior month
mom AS (
    SELECT
        l.OrderMonth,
        l.YearMonth,
        l.PaidOrders,
        prev.PaidOrders AS PrevMonth_Orders,
        ROUND(
            (l.PaidOrders - prev.PaidOrders) * 100.0
            / NULLIF(prev.PaidOrders, 0), 2
        ) AS MoM_pct
    FROM last_13 l
    LEFT JOIN monthly prev
        ON prev.OrderMonth = l.OrderMonth - INTERVAL '1 month'
),

-- YoY: current vs same month last year
-- April 2013 is partial (data to day 14) so we do MTD vs MTD for that month
yoy AS (
    SELECT
        m.OrderMonth,
        m.YearMonth,
        m.PaidOrders,
        m.PrevMonth_Orders,
        m.MoM_pct,
        CASE
            -- partial month: compare to same MTD window last year
            WHEN m.OrderMonth = (SELECT DATE_TRUNC('month', MAX(OrderPaid_dt)) FROM vw_paid_orders)
            THEN (
                SELECT COUNT(OrderID)
                FROM vw_paid_orders
                WHERE OrderMonth = m.OrderMonth - INTERVAL '1 year'
                AND EXTRACT(DAY FROM OrderPaid_dt) <= (
                    SELECT EXTRACT(DAY FROM MAX(OrderPaid_dt))
                    FROM vw_paid_orders
                    WHERE OrderMonth = (SELECT DATE_TRUNC('month', MAX(OrderPaid_dt)) FROM vw_paid_orders)
                )
            )
            -- full month: straight compare
            ELSE (
                SELECT PaidOrders FROM monthly
                WHERE OrderMonth = m.OrderMonth - INTERVAL '1 year'
            )
        END AS PriorYear_Orders,
        ROUND(
            (m.PaidOrders - (
                CASE
                    WHEN m.OrderMonth = (SELECT DATE_TRUNC('month', MAX(OrderPaid_dt)) FROM vw_paid_orders)
                    THEN (
                        SELECT COUNT(OrderID) FROM vw_paid_orders
                        WHERE OrderMonth = m.OrderMonth - INTERVAL '1 year'
                        AND EXTRACT(DAY FROM OrderPaid_dt) <= (
                            SELECT EXTRACT(DAY FROM MAX(OrderPaid_dt)) FROM vw_paid_orders
                            WHERE OrderMonth = (SELECT DATE_TRUNC('month', MAX(OrderPaid_dt)) FROM vw_paid_orders)
                        )
                    )
                    ELSE (SELECT PaidOrders FROM monthly WHERE OrderMonth = m.OrderMonth - INTERVAL '1 year')
                END
            )) * 100.0 / NULLIF((
                CASE
                    WHEN m.OrderMonth = (SELECT DATE_TRUNC('month', MAX(OrderPaid_dt)) FROM vw_paid_orders)
                    THEN (
                        SELECT COUNT(OrderID) FROM vw_paid_orders
                        WHERE OrderMonth = m.OrderMonth - INTERVAL '1 year'
                        AND EXTRACT(DAY FROM OrderPaid_dt) <= (
                            SELECT EXTRACT(DAY FROM MAX(OrderPaid_dt)) FROM vw_paid_orders
                            WHERE OrderMonth = (SELECT DATE_TRUNC('month', MAX(OrderPaid_dt)) FROM vw_paid_orders)
                        )
                    )
                    ELSE (SELECT PaidOrders FROM monthly WHERE OrderMonth = m.OrderMonth - INTERVAL '1 year')
                END
            ), 0), 2
        ) AS YoY_pct
    FROM mom m
)

SELECT
    YearMonth          AS "Month",
    PaidOrders         AS "Paid Orders",
    PrevMonth_Orders   AS "Prior Month Orders",
    COALESCE(CAST(MoM_pct AS VARCHAR), 'N/A') AS "MoM Change (%)",
    PriorYear_Orders   AS "Prior Year Orders",
    COALESCE(CAST(YoY_pct AS VARCHAR), 'N/A') AS "YoY Change (%)"
FROM yoy
ORDER BY OrderMonth;


-- -------------------------------------------------------
-- Q2.1: Active Customers per month (3-month rolling)
-- Slicers in Power BI: PayIn Country, PayOut Country
-- -------------------------------------------------------

WITH reporting_months AS (
    SELECT DISTINCT OrderMonth
    FROM vw_paid_orders
    WHERE OrderMonth >= (
        SELECT DATE_TRUNC('month', MAX(OrderPaid_dt)) - INTERVAL '12 months'
        FROM vw_paid_orders
    )
)

SELECT
    TO_CHAR(rm.OrderMonth, 'YYYY-MM') AS "Month",
    COUNT(DISTINCT po.SenderKey)      AS "Active Customers (3-Month Rolling)"
FROM reporting_months rm
JOIN vw_paid_orders po
    ON po.OrderMonth BETWEEN rm.OrderMonth - INTERVAL '2 months' AND rm.OrderMonth
GROUP BY rm.OrderMonth
ORDER BY rm.OrderMonth;


-- -------------------------------------------------------
-- Q2.2: Monthly Repeat Senders and Repeat Sender Rate
-- Repeat Sender = transacted this month AND last month
-- Rate = Repeat Senders / prior month transacting customers * 100
-- -------------------------------------------------------

WITH monthly_senders AS (
    SELECT
        OrderMonth,
        SenderKey
    FROM vw_paid_orders
    GROUP BY OrderMonth, SenderKey
),

reporting_months AS (
    SELECT DISTINCT OrderMonth
    FROM vw_paid_orders
    WHERE OrderMonth >= (
        SELECT DATE_TRUNC('month', MAX(OrderPaid_dt)) - INTERVAL '12 months'
        FROM vw_paid_orders
    )
),

repeat AS (
    SELECT
        rm.OrderMonth,
        COUNT(DISTINCT curr.SenderKey) AS TransactingCustomers,
        COUNT(DISTINCT CASE WHEN prev.SenderKey IS NOT NULL THEN curr.SenderKey END) AS RepeatSenders
    FROM reporting_months rm
    JOIN monthly_senders curr ON curr.OrderMonth = rm.OrderMonth
    LEFT JOIN monthly_senders prev
        ON prev.OrderMonth = rm.OrderMonth - INTERVAL '1 month'
        AND prev.SenderKey = curr.SenderKey
    GROUP BY rm.OrderMonth
)

SELECT
    TO_CHAR(r.OrderMonth, 'YYYY-MM')    AS "Month",
    r.TransactingCustomers              AS "Transacting Customers",
    r.RepeatSenders                     AS "Monthly Repeat Senders",
    pm.PrevMonthCustomers               AS "Prev Month Customers",
    ROUND(r.RepeatSenders * 100.0 / NULLIF(pm.PrevMonthCustomers, 0), 2) AS "Repeat Sender Rate (%)"
FROM repeat r
LEFT JOIN (
    SELECT OrderMonth, COUNT(DISTINCT SenderKey) AS PrevMonthCustomers
    FROM monthly_senders
    GROUP BY OrderMonth
) pm ON pm.OrderMonth = r.OrderMonth - INTERVAL '1 month'
ORDER BY r.OrderMonth;
