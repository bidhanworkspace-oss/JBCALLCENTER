

























/




DECLARE
    v_cnt NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_cnt
    FROM ALL_TAB_COLUMNS
    WHERE OWNER = USER AND TABLE_NAME = 'USERDETAIL' AND COLUMN_NAME = 'IMAGE_PATH';
    IF v_cnt = 0 THEN
        EXECUTE IMMEDIATE 'ALTER TABLE USERDETAIL ADD (IMAGE_PATH VARCHAR2(500))';
    END IF;
END;
/







CREATE OR REPLACE PROCEDURE SP_CREATE_MANAGER_BY_SUPERADMIN (
    p_superadmin_user_id IN NUMBER,
    p_fullname IN VARCHAR2,
    p_mobile IN VARCHAR2,
    p_email IN VARCHAR2,
    p_nid IN VARCHAR2,
    p_image_path IN VARCHAR2,
    p_temp_password IN VARCHAR2,
    p_gen_bank_id OUT VARCHAR2,
    p_success OUT NUMBER,
    p_msg OUT VARCHAR2
) AS
    v_role_id NUMBER;
    v_superadmin_role VARCHAR2(50);
BEGIN

    SELECT UPPER(r.ROLE_NAME) INTO v_superadmin_role
    FROM USERDETAIL u
    JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
    WHERE u.USERDETAILID = p_superadmin_user_id;

    IF v_superadmin_role != 'SUPERADMIN' THEN
        p_success := 0;
        p_msg := 'Access Denied: Only Superadmin can create Manager accounts.';
        RETURN;
    END IF;


    SELECT ROLE_ID INTO v_role_id FROM SYSTEM_ROLE WHERE UPPER(ROLE_NAME) = 'MANAGER';

    p_gen_bank_id := 'MGR' || SEQ_BANK_ID.NEXTVAL;

    INSERT INTO USERDETAIL (
        BANKID, FULLNAME, MOBILE_NO, EMAIL, NID, IMAGE_PATH, USERPASSWORD,
        ROLE_ID, IS_FIRST_LOGIN, USERSTATUS, APPROVED_BY_USER_ID, APPROVED_AT
    ) VALUES (
        p_gen_bank_id, p_fullname, p_mobile, p_email, p_nid, p_image_path, p_temp_password,
        v_role_id, 1, 'Enabled', p_superadmin_user_id, CURRENT_TIMESTAMP
    );

    p_success := 1;
    p_msg := 'Manager account created successfully.';
    COMMIT;
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        p_success := 0;
        p_msg := 'Superadmin or Manager role definition missing.';
    WHEN OTHERS THEN
        p_success := 0;
        p_msg := SQLERRM;
END;
/






CREATE OR REPLACE PROCEDURE SP_GET_USER_DETAILS (
    p_user_id     IN  NUMBER,
    o_fullname    OUT VARCHAR2,
    o_email       OUT VARCHAR2,
    o_image_path  OUT VARCHAR2,
    o_role_name   OUT VARCHAR2,
    o_success     OUT NUMBER
) AS
BEGIN
    o_fullname   := NULL;
    o_email      := NULL;
    o_image_path := NULL;
    o_role_name  := NULL;
    o_success    := 0;

    SELECT u.FULLNAME, u.EMAIL, u.IMAGE_PATH, r.ROLE_NAME
      INTO o_fullname, o_email, o_image_path, o_role_name
      FROM USERDETAIL u
      JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
     WHERE u.USERDETAILID = p_user_id;

    o_success := 1;
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        o_success := 0;
    WHEN OTHERS THEN
        o_success := 0;
END;
/




CREATE OR REPLACE PROCEDURE SP_GET_ACTIVE_USERS (
    p_out_cursor OUT SYS_REFCURSOR
) AS
BEGIN
    OPEN p_out_cursor FOR
        SELECT u.BANKID,
               u.FULLNAME,
               u.MOBILE_NO,
               u.EMAIL,
               r.ROLE_NAME,
               u.IMAGE_PATH,
               u.USERSTATUS,
               u.APPROVED_AT
        FROM   USERDETAIL u
        JOIN   SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
        WHERE  UPPER(u.USERSTATUS) = 'ENABLED'
          AND  UPPER(r.ROLE_NAME) <> 'SUPERADMIN'
        ORDER  BY u.APPROVED_AT DESC NULLS LAST, u.FULLNAME;
END;
/




CREATE OR REPLACE PROCEDURE SP_GET_LOCKED_USERS (
    p_out_cursor OUT SYS_REFCURSOR
) AS
BEGIN
    OPEN p_out_cursor FOR
        SELECT u.BANKID,
               u.FULLNAME,
               u.EMAIL,
               u.USERSTATUS,
               u.FAILED_ATTEMPTS
        FROM   USERDETAIL u
        WHERE  UPPER(u.USERSTATUS) <> 'ENABLED'
        ORDER  BY u.USERDETAILID DESC;
END;
/




DECLARE
    v_cnt NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_cnt FROM ALL_SEQUENCES
    WHERE SEQUENCE_OWNER = USER AND SEQUENCE_NAME = 'JB_TICKETS_SEQ';
    IF v_cnt = 0 THEN
        EXECUTE IMMEDIATE 'CREATE SEQUENCE JB_TICKETS_SEQ START WITH 1 INCREMENT BY 1 NOCACHE';
    END IF;

    SELECT COUNT(*) INTO v_cnt FROM ALL_SEQUENCES
    WHERE SEQUENCE_OWNER = USER AND SEQUENCE_NAME = 'JB_TICKET_RESPONSES_SEQ';
    IF v_cnt = 0 THEN
        EXECUTE IMMEDIATE 'CREATE SEQUENCE JB_TICKET_RESPONSES_SEQ START WITH 1 INCREMENT BY 1 NOCACHE';
    END IF;
END;
/

DECLARE
    v_cnt NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_cnt FROM USER_TABLES WHERE TABLE_NAME = 'JB_TICKETS';
    IF v_cnt = 0 THEN
        EXECUTE IMMEDIATE 'CREATE TABLE JB_TICKETS (
            TICKET_ID          NUMBER       CONSTRAINT PK_JB_TICKETS PRIMARY KEY,
            TICKET_REF_NO      VARCHAR2(30) NOT NULL UNIQUE,
            ISSUE_TYPE_ID      NUMBER(2)    NOT NULL,
            ISSUE_TYPE_NAME    VARCHAR2(100) NOT NULL,
            RAISED_BY_USER_ID  NUMBER       NOT NULL,
            RAISED_BY_BANK_ID  VARCHAR2(30) NOT NULL,
            CUSTOMER_NAME      VARCHAR2(200),
            MOBILE_NO          VARCHAR2(20),
            ACCOUNT_NO         VARCHAR2(40),
            REMARKS            VARCHAR2(2000),
            ATTACHMENT_PATH    VARCHAR2(500),
            PRIORITY           VARCHAR2(20) NOT NULL
                               CONSTRAINT CK_JB_TICKET_PRIORITY
                               CHECK (PRIORITY IN (''VERY HIGH'',''HIGH'',''LOW'')),
            STATUS             VARCHAR2(20) DEFAULT ''OPEN'' NOT NULL
                               CONSTRAINT CK_JB_TICKET_STATUS
                               CHECK (STATUS IN (''OPEN'',''IN_PROGRESS'',''SOLVED'',''DENIED'')),
            CREATED_AT         TIMESTAMP    DEFAULT SYSTIMESTAMP NOT NULL,
            SOLVED_AT          TIMESTAMP
        )';
        EXECUTE IMMEDIATE 'CREATE INDEX IDX_JB_TICKET_STATUS  ON JB_TICKETS (STATUS)';
        EXECUTE IMMEDIATE 'CREATE INDEX IDX_JB_TICKET_PRIOR   ON JB_TICKETS (PRIORITY)';
    END IF;

    SELECT COUNT(*) INTO v_cnt FROM USER_TABLES WHERE TABLE_NAME = 'JB_TICKET_RESPONSES';
    IF v_cnt = 0 THEN
        EXECUTE IMMEDIATE 'CREATE TABLE JB_TICKET_RESPONSES (
            RESPONSE_ID        NUMBER      CONSTRAINT PK_JB_TICKET_RESP PRIMARY KEY,
            TICKET_ID          NUMBER      NOT NULL
                               CONSTRAINT FK_JB_RESP_TICKET REFERENCES JB_TICKETS (TICKET_ID),
            RESPONDER_USER_ID  NUMBER      NOT NULL,
            RESPONDER_BANK_ID  VARCHAR2(30),
            ACTION_TAKEN       VARCHAR2(20) NOT NULL
                               CONSTRAINT CK_JB_RESP_ACTION
                               CHECK (ACTION_TAKEN IN (''SOLVED'',''DENIED'',''NOTE'')),
            REMARKS            VARCHAR2(2000),
            CREATED_AT         TIMESTAMP   DEFAULT SYSTIMESTAMP NOT NULL
        )';
        EXECUTE IMMEDIATE 'CREATE INDEX IDX_JB_RESP_TICKET    ON JB_TICKET_RESPONSES (TICKET_ID)';
    END IF;
END;
/

CREATE OR REPLACE TRIGGER TRG_JB_TICKETS_BI
BEFORE INSERT ON JB_TICKETS
FOR EACH ROW
WHEN (NEW.TICKET_ID IS NULL)
BEGIN
   SELECT JB_TICKETS_SEQ.NEXTVAL INTO :NEW.TICKET_ID FROM DUAL;
   :NEW.TICKET_REF_NO := 'TKT-' || TO_CHAR(SYSDATE, 'YYYYMMDD') || '-' || LPAD(:NEW.TICKET_ID, 4, '0');
END;
/

CREATE OR REPLACE TRIGGER TRG_JB_TICKET_RESP_BI
BEFORE INSERT ON JB_TICKET_RESPONSES
FOR EACH ROW
WHEN (NEW.RESPONSE_ID IS NULL)
BEGIN
   SELECT JB_TICKET_RESPONSES_SEQ.NEXTVAL INTO :NEW.RESPONSE_ID FROM DUAL;
END;
/






CREATE OR REPLACE PROCEDURE SP_RAISE_TICKET (
    p_raised_by_user_id  IN NUMBER,
    p_raised_by_bank_id  IN VARCHAR2,
    p_issue_type_id      IN NUMBER,
    p_issue_type_name    IN VARCHAR2,
    p_customer_name      IN VARCHAR2,
    p_mobile_no          IN VARCHAR2,
    p_account_no         IN VARCHAR2,
    p_remarks            IN VARCHAR2,
    p_attachment_path    IN VARCHAR2,
    p_priority           IN VARCHAR2,
    o_ticket_id          OUT NUMBER,
    o_ticket_ref         OUT VARCHAR2,
    o_success            OUT NUMBER,
    o_msg                OUT VARCHAR2
) AS
    v_ticket_id NUMBER;
BEGIN
    o_success := 0;

    IF p_priority NOT IN ('VERY HIGH','HIGH','LOW') THEN
        o_msg := 'Invalid priority.';
        RETURN;
    END IF;

    IF p_issue_type_id IS NULL THEN
        o_msg := 'Select an issue type.';
        RETURN;
    END IF;

    IF p_mobile_no IS NULL AND p_account_no IS NULL THEN
        o_msg := 'Provide at least Mobile No or Account No.';
        RETURN;
    END IF;

    INSERT INTO JB_TICKETS (
        ISSUE_TYPE_ID, ISSUE_TYPE_NAME,
        RAISED_BY_USER_ID, RAISED_BY_BANK_ID,
        CUSTOMER_NAME, MOBILE_NO, ACCOUNT_NO, REMARKS, ATTACHMENT_PATH,
        PRIORITY
    ) VALUES (
        p_issue_type_id, p_issue_type_name,
        p_raised_by_user_id, p_raised_by_bank_id,
        p_customer_name, p_mobile_no, p_account_no, p_remarks, p_attachment_path,
        p_priority
    )
    RETURNING TICKET_ID INTO v_ticket_id;

    o_ticket_id  := v_ticket_id;
    o_ticket_ref := 'TKT-' || TO_CHAR(SYSDATE, 'YYYYMMDD') || '-' || LPAD(v_ticket_id, 4, '0');
    o_success    := 1;
    o_msg        := 'Ticket raised.';
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        o_success := 0;
        o_msg     := SQLERRM;
END;
/





CREATE OR REPLACE PROCEDURE SP_GET_TICKETS (
    p_filter     IN VARCHAR2 DEFAULT 'LATEST',
    p_out_cursor OUT SYS_REFCURSOR
) AS
BEGIN
    IF UPPER(NVL(p_filter, 'LATEST')) = 'PRIORITY' THEN
        OPEN p_out_cursor FOR
            SELECT t.TICKET_ID,
                   t.TICKET_REF_NO,
                   t.ISSUE_TYPE_NAME,
                   t.CUSTOMER_NAME,
                   t.MOBILE_NO,
                   t.ACCOUNT_NO,
                   t.PRIORITY,
                   t.STATUS,
                   t.RAISED_BY_BANK_ID,
                   t.CREATED_AT,
                   (SELECT COUNT(*) FROM JB_TICKET_RESPONSES r
                     WHERE r.TICKET_ID = t.TICKET_ID) AS RESPONSE_COUNT,
                   CASE WHEN t.STATUS IN ('SOLVED','DENIED') THEN NULL
                        ELSE ROUND(SYSDATE - CAST(t.CREATED_AT AS DATE)) END AS OPEN_DAYS
            FROM   JB_TICKETS t
            ORDER  BY CASE t.PRIORITY
                         WHEN 'VERY HIGH' THEN 1
                         WHEN 'HIGH'      THEN 2
                         ELSE 3
                      END,
                      t.CREATED_AT DESC;
    ELSE
        OPEN p_out_cursor FOR
            SELECT t.TICKET_ID,
                   t.TICKET_REF_NO,
                   t.ISSUE_TYPE_NAME,
                   t.CUSTOMER_NAME,
                   t.MOBILE_NO,
                   t.ACCOUNT_NO,
                   t.PRIORITY,
                   t.STATUS,
                   t.RAISED_BY_BANK_ID,
                   t.CREATED_AT,
                   (SELECT COUNT(*) FROM JB_TICKET_RESPONSES r
                     WHERE r.TICKET_ID = t.TICKET_ID) AS RESPONSE_COUNT,
                   CASE WHEN t.STATUS IN ('SOLVED','DENIED') THEN NULL
                        ELSE ROUND(SYSDATE - CAST(t.CREATED_AT AS DATE)) END AS OPEN_DAYS
            FROM   JB_TICKETS t
            ORDER  BY t.CREATED_AT DESC;
    END IF;
END;
/

-- SP_SEARCH_TICKETS: DB-side filtered + paginated ticket query.
-- Kept separate from SP_GET_TICKETS so existing callers are unaffected.
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
                   MOBILE_NO, ACCOUNT_NO, PRIORITY, STATUS, RAISED_BY_BANK_ID,
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
                           t.RAISED_BY_BANK_ID,
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
                   MOBILE_NO, ACCOUNT_NO, PRIORITY, STATUS, RAISED_BY_BANK_ID,
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
                           t.RAISED_BY_BANK_ID,
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






CREATE OR REPLACE PROCEDURE SP_GET_TICKET_BY_ID (
    p_ticket_id     IN NUMBER,
    o_ticket_cursor OUT SYS_REFCURSOR
) AS
BEGIN
    OPEN o_ticket_cursor FOR
        'SELECT TICKET_ID, TICKET_REF_NO, ISSUE_TYPE_NAME,
                CUSTOMER_NAME, MOBILE_NO, ACCOUNT_NO,
                REMARKS, ATTACHMENT_PATH, PRIORITY, STATUS,
                RAISED_BY_BANK_ID, CREATED_AT
         FROM   JB_TICKETS
         WHERE  TICKET_ID = :b'
        USING p_ticket_id;
END;
/

CREATE OR REPLACE PROCEDURE SP_GET_TICKET_RESPONSES (
    p_ticket_id     IN NUMBER,
    o_response_cur  OUT SYS_REFCURSOR
) AS
BEGIN
    OPEN o_response_cur FOR
        'SELECT RESPONDER_BANK_ID,
                ACTION_TAKEN,
                REMARKS,
                CREATED_AT
         FROM   JB_TICKET_RESPONSES
         WHERE  TICKET_ID = :b
         ORDER  BY CREATED_AT ASC'
        USING p_ticket_id;
END;
/


CREATE OR REPLACE PROCEDURE SP_RESPOND_TICKET (
    p_ticket_id         IN NUMBER,
    p_responder_user_id IN NUMBER,
    p_responder_bank_id IN VARCHAR2,
    p_action            IN VARCHAR2,
    p_remarks           IN VARCHAR2,
    o_success           OUT NUMBER,
    o_msg               OUT VARCHAR2
) AS
    v_status VARCHAR2(20);
BEGIN
    o_success := 0;

    IF p_action NOT IN ('SOLVED','DENIED','NOTE') THEN
        o_msg := 'Invalid action.';
        RETURN;
    END IF;

    IF TRIM(NVL(p_remarks, ' ')) IS NULL THEN
        o_msg := 'Remarks are required before responding.';
        RETURN;
    END IF;

    BEGIN
        SELECT STATUS INTO v_status
        FROM   JB_TICKETS
        WHERE  TICKET_ID = p_ticket_id
        FOR UPDATE;

        IF NVL(v_status, 'CLOSED') IN ('SOLVED','DENIED') AND p_action IN ('SOLVED','DENIED') THEN
            o_msg := 'This ticket is already closed.';
            RETURN;
        END IF;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            o_msg := 'Ticket not found.';
            RETURN;
    END;

    INSERT INTO JB_TICKET_RESPONSES (
        RESPONSE_ID, TICKET_ID,
        RESPONDER_USER_ID, RESPONDER_BANK_ID,
        ACTION_TAKEN, REMARKS
    ) VALUES (
        JB_TICKET_RESPONSES_SEQ.NEXTVAL, p_ticket_id,
        p_responder_user_id, p_responder_bank_id,
        p_action, TRIM(p_remarks)
    );

    IF p_action = 'SOLVED' THEN
        UPDATE JB_TICKETS SET STATUS = 'SOLVED', SOLVED_AT = SYSTIMESTAMP
        WHERE TICKET_ID = p_ticket_id;
    ELSIF p_action = 'DENIED' THEN
        UPDATE JB_TICKETS SET STATUS = 'DENIED', SOLVED_AT = SYSTIMESTAMP
        WHERE TICKET_ID = p_ticket_id;
    ELSE
        IF v_status = 'OPEN' THEN
            UPDATE JB_TICKETS SET STATUS = 'IN_PROGRESS'
            WHERE TICKET_ID = p_ticket_id;
        END IF;
    END IF;

    o_success := 1;
    o_msg     := 'Response recorded.';
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        o_success := 0;
        o_msg     := SQLERRM;
END;
/








DECLARE
    v_mid NUMBER;
BEGIN

    BEGIN
        SELECT MENU_ID INTO v_mid FROM SYSTEM_MENU WHERE URL_NAME = 'raise_ticket';
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            INSERT INTO SYSTEM_MENU (MENU_TITLE, URL_NAME, PARENT_ID, ICON_CLASS, DISPLAY_ORDER)
            VALUES ('Raise Ticket', 'raise_ticket', NULL, 'bi-plus-circle', 7)
            RETURNING MENU_ID INTO v_mid;
    END;


    BEGIN
        SELECT MENU_ID INTO v_mid FROM SYSTEM_MENU WHERE URL_NAME = 'tickets';
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            INSERT INTO SYSTEM_MENU (MENU_TITLE, URL_NAME, PARENT_ID, ICON_CLASS, DISPLAY_ORDER)
            VALUES ('Tickets', 'tickets', NULL, 'bi-ticket-perforated', 8)
            RETURNING MENU_ID INTO v_mid;
    END;


    INSERT INTO ROLE_MENU_PERMISSION (ROLE_ID, MENU_ID)
        SELECT 1, MENU_ID FROM SYSTEM_MENU m
        WHERE NOT EXISTS (SELECT 1 FROM ROLE_MENU_PERMISSION rmp
                           WHERE rmp.ROLE_ID = 1 AND rmp.MENU_ID = m.MENU_ID);



    INSERT INTO ROLE_MENU_PERMISSION (ROLE_ID, MENU_ID)
        SELECT 2, MENU_ID FROM SYSTEM_MENU m
        WHERE m.URL_NAME IN ('dashboard','manager_dashboard','pending_registration',
                             'audit_trail','change_password','raise_ticket','tickets')
          AND NOT EXISTS (SELECT 1 FROM ROLE_MENU_PERMISSION rmp
                           WHERE rmp.ROLE_ID = 2 AND rmp.MENU_ID = m.MENU_ID);


    INSERT INTO ROLE_MENU_PERMISSION (ROLE_ID, MENU_ID)
        SELECT 3, MENU_ID FROM SYSTEM_MENU m
        WHERE m.URL_NAME IN ('dashboard','change_password','raise_ticket','tickets')
          AND NOT EXISTS (SELECT 1 FROM ROLE_MENU_PERMISSION rmp
                           WHERE rmp.ROLE_ID = 3 AND rmp.MENU_ID = m.MENU_ID);

    COMMIT;
END;
/




