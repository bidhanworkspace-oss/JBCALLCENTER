-- =============================================================================
-- JB Call Center - Ticket Search + Pagination (large volume support)
-- -----------------------------------------------------------------------------
-- Adds SP_SEARCH_TICKETS, a DB-side filtered / paginated ticket query used by
-- the "Tickets" page. The existing SP_GET_TICKETS procedure is intentionally
-- left untouched so anything already calling it keeps working.
--
-- Assumes the current schema where JB_TICKETS.RAISED_BY_USERID exists
-- (see JB_CALLCENTER_SETUP.sql / JB_CALLCENTER_MIGRATION_NO_TRIGGER_SEQUENCE.sql).
-- If your schema still has RAISED_BY_BANK_ID, replace RAISED_BY_USERID with
-- RAISED_BY_BANK_ID below (or run the ticket-system migration first).
--
-- Safe to run multiple times (CREATE OR REPLACE + guarded index creation).
-- =============================================================================

SET DEFINE OFF;

-- TICKET_REF_NO is NOT indexed here: it is declared UNIQUE, so Oracle already
-- maintains an index on it (creating another one raises ORA-01408).
DECLARE
    v_cnt NUMBER;
BEGIN
    SELECT COUNT(*)
      INTO v_cnt
      FROM USER_IND_COLUMNS uc
      JOIN USER_INDEXES ui ON ui.INDEX_NAME = uc.INDEX_NAME
     WHERE ui.TABLE_NAME = 'JB_TICKETS'
       AND uc.COLUMN_NAME = 'CREATED_AT';
    IF v_cnt = 0 THEN
        EXECUTE IMMEDIATE 'CREATE INDEX IDX_JB_TICKET_CREATED ON JB_TICKETS (CREATED_AT)';
    END IF;

    SELECT COUNT(*)
      INTO v_cnt
      FROM USER_IND_COLUMNS uc
      JOIN USER_INDEXES ui ON ui.INDEX_NAME = uc.INDEX_NAME
     WHERE ui.TABLE_NAME = 'JB_TICKETS'
       AND uc.COLUMN_NAME = 'MOBILE_NO';
    IF v_cnt = 0 THEN
        EXECUTE IMMEDIATE 'CREATE INDEX IDX_JB_TICKET_MOBILE ON JB_TICKETS (MOBILE_NO)';
    END IF;
END;
/

CREATE OR REPLACE PROCEDURE SP_SEARCH_TICKETS (
    p_filter     IN  VARCHAR2 DEFAULT 'LATEST',
    p_ticket_no  IN  VARCHAR2 DEFAULT NULL,
    p_mobile_no  IN  VARCHAR2 DEFAULT NULL,
    p_date_from  IN  VARCHAR2 DEFAULT NULL,
    p_date_to    IN  VARCHAR2 DEFAULT NULL,
    p_offset     IN  NUMBER   DEFAULT 0,
    p_limit      IN  NUMBER   DEFAULT NULL,
    p_out_cursor OUT SYS_REFCURSOR,
    o_total      OUT NUMBER
) AS
    v_priority VARCHAR2(20) := UPPER(NVL(p_filter, 'LATEST'));
    v_offset   NUMBER := NVL(p_offset, 0);
    v_from     DATE;
    v_to       DATE;

    FUNCTION parse_date (p IN VARCHAR2) RETURN DATE IS
    BEGIN
        IF p IS NULL OR TRIM(p) IS NULL THEN
            RETURN NULL;
        END IF;
        RETURN TO_DATE(TRIM(p), 'YYYY-MM-DD');
    EXCEPTION
        WHEN OTHERS THEN
            RETURN NULL;
    END;
BEGIN
    v_from := parse_date(p_date_from);
    v_to   := parse_date(p_date_to);

    SELECT COUNT(*)
      INTO o_total
      FROM JB_TICKETS t
     WHERE (p_ticket_no IS NULL OR UPPER(t.TICKET_REF_NO) LIKE '%' || UPPER(p_ticket_no) || '%')
       AND (p_mobile_no IS NULL OR t.MOBILE_NO LIKE '%' || p_mobile_no || '%')
       AND (v_from IS NULL OR TRUNC(CAST(t.CREATED_AT AS DATE)) >= v_from)
       AND (v_to   IS NULL OR TRUNC(CAST(t.CREATED_AT AS DATE)) <= v_to);

    IF v_priority = 'PRIORITY' THEN
        OPEN p_out_cursor FOR
            SELECT TICKET_ID, TICKET_REF_NO, ISSUE_TYPE_NAME, CUSTOMER_NAME,
                   MOBILE_NO, ACCOUNT_NO, PRIORITY, STATUS, RAISED_BY_USERID,
                   CREATED_AT, RESPONSE_COUNT, OPEN_DAYS
              FROM (
                    SELECT t.TICKET_ID,
                           t.TICKET_REF_NO,
                           t.ISSUE_TYPE_NAME,
                           t.CUSTOMER_NAME,
                           t.MOBILE_NO,
                           t.ACCOUNT_NO,
                           t.PRIORITY,
                           t.STATUS,
                           t.RAISED_BY_USERID,
                           t.CREATED_AT,
                           (SELECT COUNT(*) FROM JB_TICKET_RESPONSES r
                             WHERE r.TICKET_ID = t.TICKET_ID) AS RESPONSE_COUNT,
                           CASE WHEN t.STATUS IN ('SOLVED','DENIED') THEN NULL
                                ELSE ROUND(SYSDATE - CAST(t.CREATED_AT AS DATE)) END AS OPEN_DAYS,
                           ROW_NUMBER() OVER (
                               ORDER BY CASE t.PRIORITY
                                            WHEN 'VERY HIGH' THEN 1
                                            WHEN 'HIGH'      THEN 2
                                            ELSE 3
                                        END,
                                        t.CREATED_AT DESC
                           ) AS RN
                      FROM JB_TICKETS t
                     WHERE (p_ticket_no IS NULL OR UPPER(t.TICKET_REF_NO) LIKE '%' || UPPER(p_ticket_no) || '%')
                       AND (p_mobile_no IS NULL OR t.MOBILE_NO LIKE '%' || p_mobile_no || '%')
                       AND (v_from IS NULL OR TRUNC(CAST(t.CREATED_AT AS DATE)) >= v_from)
                       AND (v_to   IS NULL OR TRUNC(CAST(t.CREATED_AT AS DATE)) <= v_to)
                   )
             WHERE RN > v_offset
               AND (p_limit IS NULL OR RN <= v_offset + p_limit)
             ORDER BY RN;
    ELSE
        OPEN p_out_cursor FOR
            SELECT TICKET_ID, TICKET_REF_NO, ISSUE_TYPE_NAME, CUSTOMER_NAME,
                   MOBILE_NO, ACCOUNT_NO, PRIORITY, STATUS, RAISED_BY_USERID,
                   CREATED_AT, RESPONSE_COUNT, OPEN_DAYS
              FROM (
                    SELECT t.TICKET_ID,
                           t.TICKET_REF_NO,
                           t.ISSUE_TYPE_NAME,
                           t.CUSTOMER_NAME,
                           t.MOBILE_NO,
                           t.ACCOUNT_NO,
                           t.PRIORITY,
                           t.STATUS,
                           t.RAISED_BY_USERID,
                           t.CREATED_AT,
                           (SELECT COUNT(*) FROM JB_TICKET_RESPONSES r
                             WHERE r.TICKET_ID = t.TICKET_ID) AS RESPONSE_COUNT,
                           CASE WHEN t.STATUS IN ('SOLVED','DENIED') THEN NULL
                                ELSE ROUND(SYSDATE - CAST(t.CREATED_AT AS DATE)) END AS OPEN_DAYS,
                           ROW_NUMBER() OVER (ORDER BY t.CREATED_AT DESC) AS RN
                      FROM JB_TICKETS t
                     WHERE (p_ticket_no IS NULL OR UPPER(t.TICKET_REF_NO) LIKE '%' || UPPER(p_ticket_no) || '%')
                       AND (p_mobile_no IS NULL OR t.MOBILE_NO LIKE '%' || p_mobile_no || '%')
                       AND (v_from IS NULL OR TRUNC(CAST(t.CREATED_AT AS DATE)) >= v_from)
                       AND (v_to   IS NULL OR TRUNC(CAST(t.CREATED_AT AS DATE)) <= v_to)
                   )
             WHERE RN > v_offset
               AND (p_limit IS NULL OR RN <= v_offset + p_limit)
             ORDER BY RN;
    END IF;
END;
/
