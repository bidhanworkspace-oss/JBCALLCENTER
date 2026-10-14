
WHENEVER SQLERROR CONTINUE
/





CREATE TABLE SYSTEM_ROLE (
    ROLE_ID     NUMBER GENERATED ALWAYS AS IDENTITY,
    ROLE_NAME   VARCHAR2(50)  NOT NULL,
    DESCRIPTION VARCHAR2(255),
    CONSTRAINT PK_SYSTEM_ROLE PRIMARY KEY (ROLE_ID),
    CONSTRAINT UQ_SYSTEM_ROLE_NAME UNIQUE (ROLE_NAME)
);

CREATE TABLE SYSTEM_MENU (
    MENU_ID       NUMBER GENERATED ALWAYS AS IDENTITY,
    MENU_TITLE    VARCHAR2(100) NOT NULL,
    URL_NAME      VARCHAR2(100) NOT NULL,
    PARENT_ID     NUMBER,
    ICON_CLASS    VARCHAR2(50),
    DISPLAY_ORDER NUMBER DEFAULT 1,
    CONSTRAINT PK_SYSTEM_MENU PRIMARY KEY (MENU_ID),
    CONSTRAINT UQ_SYSTEM_MENU_URL UNIQUE (URL_NAME),
    CONSTRAINT FK_SYSTEM_MENU_PARENT FOREIGN KEY (PARENT_ID) REFERENCES SYSTEM_MENU (MENU_ID)
);

CREATE TABLE ROLE_MENU_PERMISSION (
    ROLE_ID NUMBER NOT NULL,
    MENU_ID NUMBER NOT NULL,
    CONSTRAINT PK_ROLE_MENU_PERMISSION PRIMARY KEY (ROLE_ID, MENU_ID),
    CONSTRAINT FK_RMP_ROLE FOREIGN KEY (ROLE_ID) REFERENCES SYSTEM_ROLE (ROLE_ID),
    CONSTRAINT FK_RMP_MENU FOREIGN KEY (MENU_ID) REFERENCES SYSTEM_MENU (MENU_ID)
);

CREATE TABLE USERDETAIL (
    USERDETAILID        NUMBER GENERATED ALWAYS AS IDENTITY,
    USERID              VARCHAR2(30),
    FULLNAME            VARCHAR2(100),
    MOBILE_NO           VARCHAR2(20) NOT NULL,
    EMAIL               VARCHAR2(100) NOT NULL,
    NID                 VARCHAR2(30),
    OFFICE_ID           VARCHAR2(30),
    ATTACHMENT_PATH     VARCHAR2(255),
    USERPASSWORD        VARCHAR2(255),
    IS_FIRST_LOGIN      NUMBER DEFAULT 1,
    USERSTATUS          VARCHAR2(20) DEFAULT 'Enabled',
    FAILED_ATTEMPTS     NUMBER DEFAULT 0,
    CREATED_AT          TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    ROLE_ID             NUMBER,
    APPROVED_BY_USER_ID NUMBER,
    APPROVED_AT         TIMESTAMP,
    IMAGE_PATH          VARCHAR2(500),
    CONSTRAINT PK_USERDETAIL PRIMARY KEY (USERDETAILID),
    CONSTRAINT UQ_USERDETAIL_USERID UNIQUE (USERID),
    CONSTRAINT FK_USERDETAIL_ROLE FOREIGN KEY (ROLE_ID) REFERENCES SYSTEM_ROLE (ROLE_ID),
    CONSTRAINT FK_USERDETAIL_APPROVER FOREIGN KEY (APPROVED_BY_USER_ID) REFERENCES USERDETAIL (USERDETAILID)
);

CREATE TABLE USER_REGISTRATION (
    REGISTRATION_ID NUMBER GENERATED ALWAYS AS IDENTITY,
    FULLNAME        VARCHAR2(100),
    MOBILE_NO       VARCHAR2(20) NOT NULL,
    EMAIL           VARCHAR2(100) NOT NULL,
    NID             VARCHAR2(30),
    OFFICE_ID       VARCHAR2(30),
    ATTACHMENT_PATH VARCHAR2(255),
    STATUS          VARCHAR2(20) DEFAULT 'PENDING',
    SUBMITTED_AT    TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT PK_USER_REGISTRATION PRIMARY KEY (REGISTRATION_ID)
);

CREATE UNIQUE INDEX UQ_USERDETAIL_EMAIL ON USERDETAIL (LOWER(TRIM(EMAIL)));
CREATE UNIQUE INDEX UQ_USERDETAIL_MOBILE ON USERDETAIL (TRIM(MOBILE_NO));
CREATE UNIQUE INDEX UQ_USER_REG_EMAIL ON USER_REGISTRATION (LOWER(TRIM(EMAIL)));
CREATE UNIQUE INDEX UQ_USER_REG_MOBILE ON USER_REGISTRATION (TRIM(MOBILE_NO));

CREATE TABLE USER_ACTION_AUDIT_LOG (
    LOG_ID          NUMBER GENERATED ALWAYS AS IDENTITY,
    USER_ID         NUMBER,
    USERID          VARCHAR2(30),
    ROLE_NAME       VARCHAR2(50),
    ACTION_TYPE     VARCHAR2(50) NOT NULL,
    URL_PATH        VARCHAR2(255) NOT NULL,
    HTTP_METHOD     VARCHAR2(10) NOT NULL,
    IP_ADDRESS      VARCHAR2(45),
    REQUEST_DATA    CLOB,
    RESPONSE_STATUS NUMBER,
    "TIMESTAMP"     TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT PK_USER_ACTION_AUDIT_LOG PRIMARY KEY (LOG_ID)
);





CREATE TABLE JB_TICKETS (
    TICKET_ID          NUMBER CONSTRAINT PK_JB_TICKETS PRIMARY KEY,
    TICKET_REF_NO      VARCHAR2(30) NOT NULL UNIQUE,
    ISSUE_TYPE_ID      NUMBER(2)    NOT NULL,
    ISSUE_TYPE_NAME    VARCHAR2(100) NOT NULL,
    RAISED_BY_USER_ID  NUMBER       NOT NULL,
    RAISED_BY_USERID   VARCHAR2(30) NOT NULL,
    CUSTOMER_NAME      VARCHAR2(200),
    MOBILE_NO          VARCHAR2(20),
    ACCOUNT_NO         VARCHAR2(40),
    REMARKS            VARCHAR2(2000),
    ATTACHMENT_PATH    VARCHAR2(500),
    PRIORITY           VARCHAR2(20) NOT NULL
                       CONSTRAINT CK_JB_TICKET_PRIORITY
                       CHECK (PRIORITY IN ('VERY HIGH','HIGH','LOW')),
    STATUS             VARCHAR2(20) DEFAULT 'OPEN' NOT NULL
                       CONSTRAINT CK_JB_TICKET_STATUS
                       CHECK (STATUS IN ('OPEN','IN_PROGRESS','SOLVED','DENIED')),
    CREATED_AT         TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
    SOLVED_AT          TIMESTAMP
);

CREATE INDEX IDX_JB_TICKET_STATUS ON JB_TICKETS (STATUS);
CREATE INDEX IDX_JB_TICKET_PRIOR  ON JB_TICKETS (PRIORITY);
CREATE INDEX IDX_JB_TICKET_CREATED ON JB_TICKETS (CREATED_AT);
CREATE INDEX IDX_JB_TICKET_MOBILE  ON JB_TICKETS (MOBILE_NO);

CREATE TABLE JB_TICKET_RESPONSES (
    RESPONSE_ID        NUMBER CONSTRAINT PK_JB_TICKET_RESP PRIMARY KEY,
    TICKET_ID          NUMBER      NOT NULL
                       CONSTRAINT FK_JB_RESP_TICKET REFERENCES JB_TICKETS (TICKET_ID),
    RESPONDER_USER_ID  NUMBER      NOT NULL,
    RESPONDER_USERID   VARCHAR2(30),
    ACTION_TAKEN       VARCHAR2(20) NOT NULL
                       CONSTRAINT CK_JB_RESP_ACTION
                       CHECK (ACTION_TAKEN IN ('SOLVED','DENIED','NOTE')),
    REMARKS            VARCHAR2(2000),
    CREATED_AT         TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL
);

CREATE INDEX IDX_JB_RESP_TICKET ON JB_TICKET_RESPONSES (TICKET_ID);




CREATE TABLE USER_MENU_ASSIGNMENT (
    USERDETAILID      NUMBER NOT NULL,
    MENU_ID           NUMBER NOT NULL,
    ASSIGNED_BY_USER_ID NUMBER,
    ASSIGNED_AT       TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT PK_USER_MENU_ASSIGNMENT PRIMARY KEY (USERDETAILID, MENU_ID)
);

CREATE INDEX IDX_UMA_MENU ON USER_MENU_ASSIGNMENT (MENU_ID);





CREATE TABLE JB_APP_COUNTER (
    COUNTER_NAME VARCHAR2(60) CONSTRAINT PK_JB_APP_COUNTER PRIMARY KEY,
    NEXT_VALUE   NUMBER       NOT NULL
);

CREATE OR REPLACE FUNCTION FN_GET_NEXT_ID(p_counter_name IN VARCHAR2) RETURN NUMBER IS
    v_next NUMBER;
BEGIN
    SELECT NEXT_VALUE INTO v_next
      FROM JB_APP_COUNTER
     WHERE COUNTER_NAME = p_counter_name
       FOR UPDATE;

    UPDATE JB_APP_COUNTER SET NEXT_VALUE = v_next + 1
     WHERE COUNTER_NAME = p_counter_name;

    RETURN v_next;
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        BEGIN
            INSERT INTO JB_APP_COUNTER (COUNTER_NAME, NEXT_VALUE)
            VALUES (p_counter_name, 2);
            RETURN 1;
        EXCEPTION
            WHEN DUP_VAL_ON_INDEX THEN
                SELECT NEXT_VALUE INTO v_next
                  FROM JB_APP_COUNTER
                 WHERE COUNTER_NAME = p_counter_name
                   FOR UPDATE;
                UPDATE JB_APP_COUNTER SET NEXT_VALUE = v_next + 1
                 WHERE COUNTER_NAME = p_counter_name;
                RETURN v_next;
        END;
END;
/


INSERT INTO JB_APP_COUNTER (COUNTER_NAME, NEXT_VALUE) VALUES ('JB_TICKETS_SEQ', 1);
INSERT INTO JB_APP_COUNTER (COUNTER_NAME, NEXT_VALUE) VALUES ('JB_TICKET_RESPONSES_SEQ', 1);
INSERT INTO JB_APP_COUNTER (COUNTER_NAME, NEXT_VALUE) VALUES ('BANK_USER_SEQ', 1);
INSERT INTO JB_APP_COUNTER (COUNTER_NAME, NEXT_VALUE) VALUES ('MANAGER_USER_SEQ', 1);
COMMIT;





INSERT INTO SYSTEM_ROLE (ROLE_NAME, DESCRIPTION) VALUES ('Superadmin', 'Full system access.');
INSERT INTO SYSTEM_ROLE (ROLE_NAME, DESCRIPTION) VALUES ('Manager',    'Manages users and tickets.');
INSERT INTO SYSTEM_ROLE (ROLE_NAME, DESCRIPTION) VALUES ('User',       'Bank user.');
INSERT INTO SYSTEM_ROLE (ROLE_NAME, DESCRIPTION) VALUES ('Bank Support','Resolves and takes action on support tickets.');

INSERT INTO SYSTEM_MENU (MENU_TITLE, URL_NAME, ICON_CLASS, DISPLAY_ORDER) VALUES ('Dashboard',        'dashboard',            'bi-speedometer2',       1);
INSERT INTO SYSTEM_MENU (MENU_TITLE, URL_NAME, ICON_CLASS, DISPLAY_ORDER) VALUES ('Manager Dashboard','manager_dashboard',    'bi-person-gear',       2);
INSERT INTO SYSTEM_MENU (MENU_TITLE, URL_NAME, ICON_CLASS, DISPLAY_ORDER) VALUES ('Pending Registration','pending_registration','bi-person-plus',      3);
INSERT INTO SYSTEM_MENU (MENU_TITLE, URL_NAME, ICON_CLASS, DISPLAY_ORDER) VALUES ('Assign Menu',      'assign_menu',           'bi-person-badge',      4);
INSERT INTO SYSTEM_MENU (MENU_TITLE, URL_NAME, ICON_CLASS, DISPLAY_ORDER) VALUES ('Audit Trail',      'audit_trail',           'bi-clock-history',     5);
INSERT INTO SYSTEM_MENU (MENU_TITLE, URL_NAME, ICON_CLASS, DISPLAY_ORDER) VALUES ('Create Manager',   'create_manager',        'bi-person-badge',      6);
INSERT INTO SYSTEM_MENU (MENU_TITLE, URL_NAME, ICON_CLASS, DISPLAY_ORDER) VALUES ('Change Password',  'change_password',       'bi-key',               7);
INSERT INTO SYSTEM_MENU (MENU_TITLE, URL_NAME, ICON_CLASS, DISPLAY_ORDER) VALUES ('Raise Ticket',     'raise_ticket',          'bi-plus-circle',       8);
INSERT INTO SYSTEM_MENU (MENU_TITLE, URL_NAME, ICON_CLASS, DISPLAY_ORDER) VALUES ('Tickets',          'tickets',               'bi-ticket-perforated', 9);
INSERT INTO SYSTEM_MENU (MENU_TITLE, URL_NAME, ICON_CLASS, DISPLAY_ORDER) VALUES ('User Unlock',      'user_unlock',           'bi-unlock',           10);
INSERT INTO SYSTEM_MENU (MENU_TITLE, URL_NAME, ICON_CLASS, DISPLAY_ORDER) VALUES ('Disable/Enable',   'disable_enable',        'bi-toggle2-on',       11);

DECLARE
    v_mgr_mid NUMBER;
    v_mid NUMBER;
BEGIN
    SELECT MENU_ID INTO v_mgr_mid FROM SYSTEM_MENU WHERE URL_NAME = 'manager_dashboard';



    INSERT INTO SYSTEM_MENU (MENU_TITLE, URL_NAME, PARENT_ID, ICON_CLASS, DISPLAY_ORDER)
    VALUES ('Approve User Action', 'approve_user', v_mgr_mid, NULL, 20);
    INSERT INTO SYSTEM_MENU (MENU_TITLE, URL_NAME, PARENT_ID, ICON_CLASS, DISPLAY_ORDER)
    VALUES ('Unlock User Action', 'unlock_user', v_mgr_mid, NULL, 21);


    INSERT INTO ROLE_MENU_PERMISSION (ROLE_ID, MENU_ID)
        SELECT 1, MENU_ID FROM SYSTEM_MENU
        WHERE NOT EXISTS (SELECT 1 FROM ROLE_MENU_PERMISSION rmp
                          WHERE rmp.ROLE_ID = 1 AND rmp.MENU_ID = SYSTEM_MENU.MENU_ID);





    INSERT INTO ROLE_MENU_PERMISSION (ROLE_ID, MENU_ID)
        SELECT 2, MENU_ID FROM SYSTEM_MENU m
    WHERE m.URL_NAME IN ('dashboard','manager_dashboard','pending_registration',
                         'audit_trail','change_password','raise_ticket','tickets',
                         'user_unlock','disable_enable','assign_menu','approve_user','unlock_user')
      AND NOT EXISTS (SELECT 1 FROM ROLE_MENU_PERMISSION rmp
                      WHERE rmp.ROLE_ID = 2 AND rmp.MENU_ID = m.MENU_ID);



    INSERT INTO ROLE_MENU_PERMISSION (ROLE_ID, MENU_ID)
        SELECT 3, MENU_ID FROM SYSTEM_MENU m
        WHERE m.URL_NAME IN ('dashboard','change_password','raise_ticket','tickets')
          AND NOT EXISTS (SELECT 1 FROM ROLE_MENU_PERMISSION rmp
                          WHERE rmp.ROLE_ID = 3 AND rmp.MENU_ID = m.MENU_ID);


    INSERT INTO ROLE_MENU_PERMISSION (ROLE_ID, MENU_ID)
        SELECT 4, MENU_ID FROM SYSTEM_MENU m
        WHERE m.URL_NAME IN ('dashboard','tickets','raise_ticket','change_password')
          AND NOT EXISTS (SELECT 1 FROM ROLE_MENU_PERMISSION rmp
                          WHERE rmp.ROLE_ID = 4 AND rmp.MENU_ID = m.MENU_ID);


    INSERT INTO USERDETAIL (
        USERID, FULLNAME, MOBILE_NO, EMAIL, USERPASSWORD,
        IS_FIRST_LOGIN, USERSTATUS, FAILED_ATTEMPTS, ROLE_ID, APPROVED_AT
    ) VALUES (
        'SA001', 'System Super Admin', '01700000000', 'admin@jbcallcenter.local',
        'pbkdf2_sha256$1500000$c0Dvm1mOEt7gVQYDuzLKTv$lbQDn2LjyoDvoHQJ4JExLAY3n0/IT2zglokD9Du6zyQ=',
        0, 'Enabled', 0, 1, CURRENT_TIMESTAMP
    ) RETURNING USERDETAILID INTO v_mid;


    INSERT INTO USER_MENU_ASSIGNMENT (USERDETAILID, MENU_ID, ASSIGNED_BY_USER_ID, ASSIGNED_AT)
        SELECT (SELECT USERDETAILID FROM USERDETAIL WHERE USERID = 'SA001'), MENU_ID, NULL, CURRENT_TIMESTAMP
        FROM SYSTEM_MENU;
    COMMIT;
END;
/





CREATE OR REPLACE PROCEDURE SP_AUTHENTICATE_USER (
    p_userid          IN VARCHAR2,
    o_user_detail_id  OUT NUMBER,
    p_hashed_password OUT VARCHAR2,
    p_is_first_login  OUT NUMBER,
    p_user_status     OUT VARCHAR2,
    p_failed_attempts OUT NUMBER,
    p_success         OUT NUMBER,
    p_msg             OUT VARCHAR2
) AS
BEGIN
    SELECT USERDETAILID, USERPASSWORD, IS_FIRST_LOGIN, USERSTATUS, FAILED_ATTEMPTS
    INTO o_user_detail_id, p_hashed_password, p_is_first_login, p_user_status, p_failed_attempts
    FROM USERDETAIL WHERE USERID = p_userid;

    p_success := 1;
    p_msg     := 'User record found.';
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        p_success := 0;
        p_msg     := 'Invalid User ID or Password.';
    WHEN OTHERS THEN
        p_success := 0;
        p_msg     := SQLERRM;
END;
/






CREATE OR REPLACE PROCEDURE SP_GET_USER_MENUS (
    p_user_detail_id IN  NUMBER,
    p_menu_cursor    OUT SYS_REFCURSOR
) AS
BEGIN
    OPEN p_menu_cursor FOR
        SELECT m.MENU_ID, m.MENU_TITLE, m.URL_NAME, m.PARENT_ID,
               m.ICON_CLASS, m.DISPLAY_ORDER
          FROM SYSTEM_MENU m
         WHERE EXISTS (SELECT 1
                         FROM USER_MENU_ASSIGNMENT uma
                        WHERE uma.USERDETAILID = p_user_detail_id
                          AND uma.MENU_ID = m.MENU_ID)
            OR (NOT EXISTS (SELECT 1
                              FROM USER_MENU_ASSIGNMENT any_uma
                             WHERE any_uma.USERDETAILID = p_user_detail_id)
            AND EXISTS (SELECT 1
                          FROM USERDETAIL u
                          JOIN ROLE_MENU_PERMISSION rmp ON rmp.ROLE_ID = u.ROLE_ID
                         WHERE u.USERDETAILID = p_user_detail_id
                           AND rmp.MENU_ID = m.MENU_ID))
      ORDER BY m.PARENT_ID NULLS FIRST, m.DISPLAY_ORDER ASC, m.MENU_ID;
END;
/

CREATE OR REPLACE PROCEDURE SP_CHECK_USER_MENU_ACCESS (
    p_user_detail_id IN NUMBER,
    p_url_name       IN VARCHAR2,
    p_has_access     OUT NUMBER
) AS
    v_count NUMBER := 0;
BEGIN
    SELECT COUNT(1) INTO v_count
      FROM SYSTEM_MENU m
     WHERE m.URL_NAME = p_url_name
       AND ( EXISTS (SELECT 1
                       FROM USER_MENU_ASSIGNMENT uma
                      WHERE uma.USERDETAILID = p_user_detail_id
                        AND uma.MENU_ID = m.MENU_ID)
          OR (NOT EXISTS (SELECT 1
                            FROM USER_MENU_ASSIGNMENT any_uma
                           WHERE any_uma.USERDETAILID = p_user_detail_id)
          AND EXISTS (SELECT 1
                        FROM USERDETAIL u
                        JOIN ROLE_MENU_PERMISSION rmp ON rmp.ROLE_ID = u.ROLE_ID
                       WHERE u.USERDETAILID = p_user_detail_id
                         AND rmp.MENU_ID = m.MENU_ID)) );

    IF v_count > 0 THEN
        p_has_access := 1;
    ELSE
        p_has_access := 0;
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        p_has_access := 0;
END;
/

CREATE OR REPLACE PROCEDURE SP_RECORD_AUDIT_LOG (
    p_user_detail_id IN NUMBER,
    p_userid         IN VARCHAR2,
    p_role_name      IN VARCHAR2,
    p_action_type    IN VARCHAR2,
    p_url_path       IN VARCHAR2,
    p_http_method    IN VARCHAR2,
    p_ip_address     IN VARCHAR2,
    p_request_data   IN CLOB,
    p_response_status IN NUMBER
) AS
PRAGMA AUTONOMOUS_TRANSACTION;
BEGIN
    INSERT INTO USER_ACTION_AUDIT_LOG (
        USER_ID, USERID, ROLE_NAME, ACTION_TYPE, URL_PATH,
        HTTP_METHOD, IP_ADDRESS, REQUEST_DATA, RESPONSE_STATUS, "TIMESTAMP"
    ) VALUES (
        p_user_detail_id, p_userid, p_role_name, p_action_type, p_url_path,
        p_http_method, p_ip_address, p_request_data, p_response_status, CURRENT_TIMESTAMP
    );
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        NULL;
END;
/

CREATE OR REPLACE PROCEDURE SP_GET_AUDIT_LOGS (
    p_cursor OUT SYS_REFCURSOR
) AS
BEGIN
    OPEN p_cursor FOR
        SELECT LOG_ID, "TIMESTAMP", USERID, ROLE_NAME, ACTION_TYPE, URL_PATH, IP_ADDRESS, RESPONSE_STATUS
        FROM USER_ACTION_AUDIT_LOG
        ORDER BY LOG_ID DESC
        FETCH FIRST 100 ROWS ONLY;
END;
/

CREATE OR REPLACE PROCEDURE SP_SUBMIT_REGISTRATION (
    p_fullname IN VARCHAR2,
    p_mobile IN VARCHAR2,
    p_email IN VARCHAR2,
    p_nid IN VARCHAR2,
    p_office_id IN VARCHAR2,
    p_attachment IN VARCHAR2,
    p_success OUT NUMBER,
    p_msg OUT VARCHAR2
) AS
    v_email      VARCHAR2(100);
    v_mobile     VARCHAR2(20);
    v_nid        VARCHAR2(30);
    v_office_id  VARCHAR2(30);
    v_user_mobile NUMBER;
    v_user_email  NUMBER;
    v_reg_mobile  NUMBER;
    v_reg_email   NUMBER;
BEGIN
    v_email     := LOWER(TRIM(p_email));
    v_mobile    := TRIM(p_mobile);
    v_nid       := TRIM(p_nid);
    v_office_id := TRIM(p_office_id);

    IF v_email IS NULL OR v_mobile IS NULL THEN
        p_success := 0;
        p_msg     := 'Mobile number and email address are required.';
        RETURN;
    END IF;

    IF v_nid IS NULL
       OR NOT REGEXP_LIKE(v_nid, '^[0-9]{10}$|^[0-9]{13}$|^[0-9]{17}$') THEN
        p_success := 0;
        p_msg     := 'NID number must be exactly 10, 13 or 17 digits.';
        RETURN;
    END IF;

    IF v_office_id IS NULL THEN
        p_success := 0;
        p_msg     := 'Office ID Number is required.';
        RETURN;
    END IF;

    SELECT COUNT(CASE WHEN TRIM(MOBILE_NO) = v_mobile THEN 1 END),
           COUNT(CASE WHEN LOWER(TRIM(EMAIL)) = v_email THEN 1 END)
      INTO v_user_mobile, v_user_email
      FROM USERDETAIL;

    IF v_user_mobile > 0 THEN
        p_success := 0;
        p_msg     := 'This mobile number is already in use by a registered user.';
        RETURN;
    END IF;

    IF v_user_email > 0 THEN
        p_success := 0;
        p_msg     := 'This email address is already in use by a registered user.';
        RETURN;
    END IF;

    SELECT COUNT(CASE WHEN TRIM(MOBILE_NO) = v_mobile THEN 1 END),
           COUNT(CASE WHEN LOWER(TRIM(EMAIL)) = v_email THEN 1 END)
      INTO v_reg_mobile, v_reg_email
      FROM USER_REGISTRATION
     WHERE STATUS = 'PENDING';

    IF v_reg_mobile > 0 THEN
        p_success := 0;
        p_msg     := 'A registration with this mobile number is already awaiting approval. Please contact your manager.';
        RETURN;
    END IF;

    IF v_reg_email > 0 THEN
        p_success := 0;
        p_msg     := 'A registration with this email address is already awaiting approval. Please contact your manager.';
        RETURN;
    END IF;

    INSERT INTO USER_REGISTRATION (FULLNAME, MOBILE_NO, EMAIL, NID, OFFICE_ID, ATTACHMENT_PATH)
    VALUES (p_fullname, v_mobile, v_email, v_nid, v_office_id, p_attachment);

    p_success := 1;
    p_msg     := 'Registration submitted successfully. Awaiting approval.';
EXCEPTION
    WHEN OTHERS THEN
        p_success := 0;
        IF SQLCODE = -1 THEN
            p_msg := 'This mobile number or email address is already in use.';
        ELSE
            p_msg := SQLERRM;
        END IF;
END;
/

CREATE OR REPLACE PROCEDURE SP_GET_PENDING_REGISTRATIONS (
    p_cursor OUT SYS_REFCURSOR
) AS
BEGIN
    OPEN p_cursor FOR
        SELECT REGISTRATION_ID, FULLNAME, MOBILE_NO, EMAIL, NID, ATTACHMENT_PATH, OFFICE_ID
        FROM USER_REGISTRATION
        WHERE STATUS = 'PENDING'
        ORDER BY REGISTRATION_ID DESC;
END;
/

CREATE OR REPLACE PROCEDURE SP_APPROVE_REGISTRATION (
    p_reg_id IN NUMBER,
    p_temp_password IN VARCHAR2,
    p_manager_user_id IN NUMBER,
    o_userid OUT VARCHAR2,
    o_user_email OUT VARCHAR2,
    p_success OUT NUMBER,
    p_msg OUT VARCHAR2
) AS
    v_fullname VARCHAR2(100);
    v_mobile   VARCHAR2(20);
    v_email    VARCHAR2(100);
    v_nid      VARCHAR2(30);
    v_office_id VARCHAR2(30);
    v_attach   VARCHAR2(255);
    v_user_role_id NUMBER;
    v_manager_role VARCHAR2(50);
    v_new_user_id  NUMBER;
    v_count    NUMBER;
BEGIN
    SELECT UPPER(r.ROLE_NAME) INTO v_manager_role
    FROM USERDETAIL u
    JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
    WHERE u.USERDETAILID = p_manager_user_id;

    IF v_manager_role NOT IN ('MANAGER', 'SUPERADMIN') THEN
        p_success := 0;
        p_msg     := 'Access Denied: Only Manager or Superadmin can approve users.';
        RETURN;
    END IF;

    SELECT ROLE_ID INTO v_user_role_id FROM SYSTEM_ROLE WHERE UPPER(ROLE_NAME) = 'USER';

    SELECT FULLNAME, MOBILE_NO, EMAIL, NID, OFFICE_ID, ATTACHMENT_PATH
    INTO v_fullname, v_mobile, v_email, v_nid, v_office_id, v_attach
    FROM USER_REGISTRATION
    WHERE REGISTRATION_ID = p_reg_id AND STATUS = 'PENDING';

    v_email  := LOWER(TRIM(v_email));
    v_mobile := TRIM(v_mobile);

    IF v_email IS NULL OR v_mobile IS NULL THEN
        p_success := 0;
        p_msg     := 'This registration has no email address or mobile number.';
        RETURN;
    END IF;

    SELECT COUNT(1) INTO v_count
      FROM USERDETAIL
     WHERE LOWER(TRIM(EMAIL)) = v_email
        OR TRIM(MOBILE_NO) = v_mobile;
    IF v_count > 0 THEN
        p_success := 0;
        p_msg     := 'A user with this email address or mobile number already exists. The registration cannot be approved.';
        RETURN;
    END IF;

    o_userid    := 'JB' || FN_GET_NEXT_ID('BANK_USER_SEQ');
    o_user_email := v_email;

    INSERT INTO USERDETAIL (
        USERID, FULLNAME, MOBILE_NO, EMAIL, NID, OFFICE_ID, ATTACHMENT_PATH,
        USERPASSWORD, ROLE_ID, IS_FIRST_LOGIN, USERSTATUS, FAILED_ATTEMPTS,
        APPROVED_BY_USER_ID, APPROVED_AT
    ) VALUES (
        o_userid, v_fullname, v_mobile, v_email, v_nid, v_office_id, v_attach,
        p_temp_password, v_user_role_id, 1, 'Enabled', 0,
        p_manager_user_id, CURRENT_TIMESTAMP
    ) RETURNING USERDETAILID INTO v_new_user_id;



    FOR mc IN (
        SELECT MENU_ID FROM SYSTEM_MENU
        WHERE URL_NAME IN ('dashboard', 'change_password')
    ) LOOP
        INSERT INTO USER_MENU_ASSIGNMENT (USERDETAILID, MENU_ID, ASSIGNED_BY_USER_ID, ASSIGNED_AT)
        VALUES (v_new_user_id, mc.MENU_ID, p_manager_user_id, CURRENT_TIMESTAMP);
    END LOOP;

    UPDATE USER_REGISTRATION SET STATUS = 'APPROVED' WHERE REGISTRATION_ID = p_reg_id;

    p_success := 1;
    p_msg     := 'User approved successfully.';
    COMMIT;
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        p_success := 0;
        p_msg     := 'Registration record or role definition missing.';
    WHEN OTHERS THEN
        p_success := 0;
        IF SQLCODE = -1 THEN
            p_msg := 'A user with this email address or mobile number already exists.';
        ELSE
            p_msg := SQLERRM;
        END IF;
END;
/

CREATE OR REPLACE PROCEDURE SP_UNLOCK_USER_BY_MANAGER (
    p_userid IN VARCHAR2,
    p_temp_hashed_password IN VARCHAR2,
    o_email OUT VARCHAR2,
    p_success OUT NUMBER,
    p_msg OUT VARCHAR2
) AS
BEGIN
    SELECT EMAIL INTO o_email FROM USERDETAIL WHERE USERID = p_userid;

    UPDATE USERDETAIL
    SET USERPASSWORD = p_temp_hashed_password,
        USERSTATUS = 'Enabled',
        IS_FIRST_LOGIN = 1,
        FAILED_ATTEMPTS = 0
    WHERE USERID = p_userid;

    p_success := 1;
    p_msg     := 'User unlocked and temporary password set.';
    COMMIT;
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        p_success := 0;
        p_msg     := 'User ID not found.';
    WHEN OTHERS THEN
        p_success := 0;
        p_msg     := SQLERRM;
END;
/

CREATE OR REPLACE PROCEDURE SP_CHANGE_PASSWORD (
    p_user_detail_id IN NUMBER,
    p_new_hashed_password IN VARCHAR2,
    p_success OUT NUMBER,
    p_msg OUT VARCHAR2
) AS
BEGIN
    UPDATE USERDETAIL
    SET USERPASSWORD = p_new_hashed_password,
        IS_FIRST_LOGIN = 0,
        USERSTATUS = 'Enabled',
        FAILED_ATTEMPTS = 0
    WHERE USERDETAILID = p_user_detail_id;

    p_success := 1;
    p_msg     := 'Password updated successfully.';
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        p_success := 0;
        p_msg     := SQLERRM;
END;
/

CREATE OR REPLACE PROCEDURE SP_CHANGE_USER_PASSWORD (
    p_user_detail_id IN NUMBER,
    p_old_hashed_password IN VARCHAR2,
    p_new_hashed_password IN VARCHAR2,
    p_success OUT NUMBER,
    p_msg OUT VARCHAR2
) AS
    v_db_password VARCHAR2(255);
BEGIN
    SELECT USERPASSWORD INTO v_db_password FROM USERDETAIL WHERE USERDETAILID = p_user_detail_id;

    IF v_db_password IS NULL THEN
        p_success := 0;
        p_msg     := 'User not found.';
        RETURN;
    END IF;

    UPDATE USERDETAIL
    SET USERPASSWORD = p_new_hashed_password, IS_FIRST_LOGIN = 0
    WHERE USERDETAILID = p_user_detail_id;

    p_success := 1;
    p_msg     := 'Password updated successfully.';
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        p_success := 0;
        p_msg     := SQLERRM;
END;
/

CREATE OR REPLACE PROCEDURE SP_FORGOT_PASSWORD_RESET (
    p_userid IN VARCHAR2,
    p_email IN VARCHAR2,
    p_temp_hashed_password IN VARCHAR2,
    o_user_detail_id OUT NUMBER,
    p_success OUT NUMBER,
    p_msg OUT VARCHAR2
) AS
BEGIN
    SELECT USERDETAILID INTO o_user_detail_id
    FROM USERDETAIL
    WHERE USERID = p_userid AND EMAIL = p_email;

    UPDATE USERDETAIL
    SET USERPASSWORD = p_temp_hashed_password,
        IS_FIRST_LOGIN = 1,
        USERSTATUS = 'Enabled',
        FAILED_ATTEMPTS = 0
    WHERE USERDETAILID = o_user_detail_id;

    p_success := 1;
    p_msg     := 'Password reset. Temporary password sent to email.';
    COMMIT;
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        p_success := 0;
        p_msg     := 'No matching active user found with provided User ID and Email.';
    WHEN OTHERS THEN
        p_success := 0;
        p_msg     := SQLERRM;
END;
/





CREATE OR REPLACE PROCEDURE SP_CREATE_MANAGER_BY_SUPERADMIN (
    p_superadmin_user_id IN  NUMBER,
    p_fullname            IN  VARCHAR2,
    p_mobile              IN  VARCHAR2,
    p_email               IN  VARCHAR2,
    p_nid                 IN  VARCHAR2,
    p_image_path          IN  VARCHAR2,
    p_temp_password       IN  VARCHAR2,
    o_userid              OUT VARCHAR2,
    p_success             OUT NUMBER,
    p_msg                 OUT VARCHAR2
) AS
    v_role_id           NUMBER;
    v_superadmin_role   VARCHAR2(50);
    v_new_user_id       NUMBER;
    v_email             VARCHAR2(100);
    v_mobile            VARCHAR2(20);
    v_count             NUMBER;
BEGIN
    SELECT UPPER(r.ROLE_NAME) INTO v_superadmin_role
      FROM USERDETAIL u
      JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
     WHERE u.USERDETAILID = p_superadmin_user_id;

    IF v_superadmin_role != 'SUPERADMIN' THEN
        p_success := 0;
        p_msg     := 'Access Denied: Only Superadmin can create Manager accounts.';
        RETURN;
    END IF;

    v_email  := LOWER(TRIM(p_email));
    v_mobile := TRIM(p_mobile);

    IF v_email IS NULL OR v_mobile IS NULL THEN
        p_success := 0;
        p_msg     := 'Mobile number and email address are required.';
        RETURN;
    END IF;

    SELECT COUNT(1) INTO v_count
      FROM USERDETAIL
     WHERE LOWER(TRIM(EMAIL)) = v_email
        OR TRIM(MOBILE_NO) = v_mobile;
    IF v_count > 0 THEN
        p_success := 0;
        p_msg     := 'A user with this email address or mobile number already exists.';
        RETURN;
    END IF;

    SELECT ROLE_ID INTO v_role_id
      FROM SYSTEM_ROLE
     WHERE UPPER(ROLE_NAME) = 'MANAGER';

    o_userid := 'MGR' || FN_GET_NEXT_ID('MANAGER_USER_SEQ');

    INSERT INTO USERDETAIL (
        USERID, FULLNAME, MOBILE_NO, EMAIL, NID, IMAGE_PATH, USERPASSWORD,
        ROLE_ID, IS_FIRST_LOGIN, USERSTATUS, APPROVED_BY_USER_ID, APPROVED_AT
    ) VALUES (
        o_userid, p_fullname, v_mobile, v_email, p_nid, p_image_path, p_temp_password,
        v_role_id, 1, 'Enabled', p_superadmin_user_id, CURRENT_TIMESTAMP
    ) RETURNING USERDETAILID INTO v_new_user_id;

    FOR mc IN (
        SELECT MENU_ID FROM SYSTEM_MENU
         WHERE URL_NAME IN (
            'dashboard', 'manager_dashboard', 'pending_registration',
            'user_unlock', 'assign_menu', 'approve_user', 'unlock_user',
            'disable_enable',
            'audit_trail', 'change_password', 'raise_ticket', 'tickets'
         )
    ) LOOP
        INSERT INTO USER_MENU_ASSIGNMENT
            (USERDETAILID, MENU_ID, ASSIGNED_BY_USER_ID, ASSIGNED_AT)
        VALUES
            (v_new_user_id, mc.MENU_ID, p_superadmin_user_id, CURRENT_TIMESTAMP);
    END LOOP;

    p_success := 1;
    p_msg     := 'Manager account created successfully.';
    COMMIT;
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        p_success := 0;
        p_msg     := 'Superadmin or Manager role definition missing.';
    WHEN OTHERS THEN
        p_success := 0;
        IF SQLCODE = -1 THEN
            p_msg := 'A user with this email address or mobile number already exists.';
        ELSE
            p_msg := SQLERRM;
        END IF;
END;
/




CREATE OR REPLACE PROCEDURE SP_REGISTER_FAILED_LOGIN (
    p_user_detail_id IN  NUMBER,
    p_max_attempts   IN  NUMBER,
    o_attempts       OUT NUMBER,
    o_disabled       OUT NUMBER,
    o_status         OUT VARCHAR2
) AS
    v_attempts NUMBER := 0;
    v_status   VARCHAR2(20) := 'ENABLED';
BEGIN
    o_attempts := 0;
    o_disabled := 0;
    o_status   := NULL;

    SELECT NVL(FAILED_ATTEMPTS, 0), UPPER(NVL(USERSTATUS, 'ENABLED'))
      INTO v_attempts, v_status
      FROM USERDETAIL
     WHERE USERDETAILID = p_user_detail_id;

    v_attempts := v_attempts + 1;
    o_attempts := v_attempts;

    UPDATE USERDETAIL
       SET FAILED_ATTEMPTS = v_attempts
     WHERE USERDETAILID = p_user_detail_id;

    IF v_attempts >= p_max_attempts AND v_status = 'ENABLED' THEN
        UPDATE USERDETAIL
           SET USERSTATUS = 'Disabled'
         WHERE USERDETAILID = p_user_detail_id;
        o_disabled := 1;
        o_status   := 'Disabled';
    ELSE
        o_status := v_status;
    END IF;

    COMMIT;
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        o_attempts := 0;
    WHEN OTHERS THEN
        o_attempts := 0;
END;
/

CREATE OR REPLACE PROCEDURE SP_RESET_FAILED_LOGIN (
    p_user_detail_id IN NUMBER
) AS
BEGIN
    UPDATE USERDETAIL
       SET FAILED_ATTEMPTS = 0
     WHERE USERDETAILID = p_user_detail_id;
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        NULL;
END;
/







CREATE OR REPLACE PROCEDURE SP_SET_USER_STATUS (
    p_actor_user_detail_id  IN NUMBER,
    p_target_user_detail_id IN NUMBER,
    p_status                IN VARCHAR2,
    p_remarks               IN VARCHAR2,
    o_userid                OUT VARCHAR2,
    p_success               OUT NUMBER,
    p_msg                   OUT VARCHAR2
) AS
    v_actor_role  VARCHAR2(50);
    v_target_role VARCHAR2(50) := '';
    v_userid      VARCHAR2(30);
    v_new_status  VARCHAR2(20);
BEGIN
    p_success := 0;
    o_userid  := NULL;

    v_new_status := UPPER(TRIM(NVL(p_status, 'ENABLED')));
    IF v_new_status NOT IN ('ENABLED', 'DISABLED', 'LOCKED') THEN
        p_msg := 'Invalid status: ' || p_status;
        RETURN;
    END IF;

    SELECT UPPER(NVL(r.ROLE_NAME, '')) INTO v_actor_role
      FROM USERDETAIL u
      LEFT JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
     WHERE u.USERDETAILID = p_actor_user_detail_id;

    IF v_actor_role NOT IN ('SUPERADMIN', 'MANAGER') THEN
        p_msg := 'Access Denied: Only a Superadmin or a Manager can enable or disable an account.';
        RETURN;
    END IF;

    BEGIN
        SELECT u.USERID, UPPER(NVL(r.ROLE_NAME, ''))
          INTO v_userid, v_target_role
          FROM USERDETAIL u
          LEFT JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
         WHERE u.USERDETAILID = p_target_user_detail_id;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            p_msg := 'Target user not found.';
            RETURN;
    END;

    o_userid := v_userid;

    IF p_actor_user_detail_id = p_target_user_detail_id THEN
        p_msg := 'You cannot change the status of your own account.';
        RETURN;
    END IF;

    IF v_actor_role = 'MANAGER' AND v_target_role <> 'USER' THEN
        p_msg := 'Access Denied: a Manager can only enable or disable a regular User account. '
              || 'Ask a Superadmin to handle ' || v_userid || '.';
        RETURN;
    END IF;

    IF v_new_status = 'ENABLED' THEN
        UPDATE USERDETAIL
           SET USERSTATUS      = 'Enabled',
               FAILED_ATTEMPTS = 0
         WHERE USERDETAILID = p_target_user_detail_id;
        p_msg := v_userid || ' has been enabled.';
    ELSE
        UPDATE USERDETAIL
           SET USERSTATUS = INITCAP(v_new_status)
         WHERE USERDETAILID = p_target_user_detail_id;
        p_msg := v_userid || ' has been ' || LOWER(INITCAP(v_new_status)) || '.';
    END IF;

    p_success := 1;
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        p_success := 0;
        p_msg     := SQLERRM;
END;
/

CREATE OR REPLACE PROCEDURE SP_ENABLE_USER (
    p_actor_user_detail_id  IN NUMBER,
    p_target_user_detail_id IN NUMBER,
    p_remarks               IN VARCHAR2,
    p_success               OUT NUMBER,
    p_msg                   OUT VARCHAR2
) AS
    v_userid VARCHAR2(30);
BEGIN
    SP_SET_USER_STATUS(p_actor_user_detail_id, p_target_user_detail_id,
                       'Enabled', p_remarks, v_userid, p_success, p_msg);
END;
/

CREATE OR REPLACE PROCEDURE SP_GET_USER_DETAILS (
    p_user_detail_id IN  NUMBER,
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

    SELECT u.FULLNAME, u.EMAIL, u.IMAGE_PATH, NVL(r.ROLE_NAME, 'No Role')
      INTO o_fullname, o_email, o_image_path, o_role_name
      FROM USERDETAIL u
      LEFT JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
     WHERE u.USERDETAILID = p_user_detail_id;

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
        SELECT u.USERID,
               u.FULLNAME,
               u.MOBILE_NO,
               u.EMAIL,
               NVL(r.ROLE_NAME, 'No Role'),
               u.IMAGE_PATH,
               u.USERSTATUS,
               u.APPROVED_AT
        FROM   USERDETAIL u
        LEFT JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
        WHERE  UPPER(u.USERSTATUS) = 'ENABLED'
          AND  UPPER(NVL(r.ROLE_NAME, '')) <> 'SUPERADMIN'
        ORDER  BY u.APPROVED_AT DESC NULLS LAST, u.FULLNAME;
END;
/

CREATE OR REPLACE PROCEDURE SP_GET_LOCKED_USERS (
    p_out_cursor OUT SYS_REFCURSOR
) AS
BEGIN
    OPEN p_out_cursor FOR
        SELECT u.USERID,
               u.FULLNAME,
               u.EMAIL,
               u.USERSTATUS,
               u.FAILED_ATTEMPTS
        FROM   USERDETAIL u
        WHERE  UPPER(u.USERSTATUS) <> 'ENABLED'
        ORDER  BY u.USERDETAILID DESC;
END;
/





CREATE OR REPLACE PROCEDURE SP_RAISE_TICKET (
    p_raised_by_user_detail_id IN NUMBER,
    p_raised_by_userid IN VARCHAR2,
    p_issue_type_id     IN NUMBER,
    p_issue_type_name   IN VARCHAR2,
    p_customer_name     IN VARCHAR2,
    p_mobile_no         IN VARCHAR2,
    p_account_no        IN VARCHAR2,
    p_remarks           IN VARCHAR2,
    p_attachment_path   IN VARCHAR2,
    p_priority          IN VARCHAR2,
    o_ticket_id         OUT NUMBER,
    o_ticket_ref        OUT VARCHAR2,
    o_success           OUT NUMBER,
    o_msg               OUT VARCHAR2
) AS
    v_ticket_id NUMBER;
    v_ticket_ref VARCHAR2(30);
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

    v_ticket_id  := FN_GET_NEXT_ID('JB_TICKETS_SEQ');
    v_ticket_ref := 'TKT-' || TO_CHAR(SYSDATE, 'YYYYMMDD') || '-' || LPAD(v_ticket_id, 4, '0');

    INSERT INTO JB_TICKETS (
        TICKET_ID, TICKET_REF_NO,
        ISSUE_TYPE_ID, ISSUE_TYPE_NAME,
        RAISED_BY_USER_ID, RAISED_BY_USERID,
        CUSTOMER_NAME, MOBILE_NO, ACCOUNT_NO, REMARKS, ATTACHMENT_PATH,
        PRIORITY
    ) VALUES (
        v_ticket_id, v_ticket_ref,
        p_issue_type_id, p_issue_type_name,
        p_raised_by_user_detail_id, p_raised_by_userid,
        p_customer_name, p_mobile_no, p_account_no, p_remarks, p_attachment_path,
        p_priority
    );

    o_ticket_id  := v_ticket_id;
    o_ticket_ref := v_ticket_ref;
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
                   t.RAISED_BY_USERID,
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
                   t.RAISED_BY_USERID,
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

CREATE OR REPLACE PROCEDURE SP_GET_TICKET_BY_ID (
    p_ticket_id     IN NUMBER,
    o_ticket_cursor OUT SYS_REFCURSOR
) AS
BEGIN
    OPEN o_ticket_cursor FOR
        'SELECT TICKET_ID, TICKET_REF_NO, ISSUE_TYPE_NAME,
                CUSTOMER_NAME, MOBILE_NO, ACCOUNT_NO,
                REMARKS, ATTACHMENT_PATH, PRIORITY, STATUS,
                RAISED_BY_USERID, CREATED_AT
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
        'SELECT RESPONDER_USERID,
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
    p_responder_user_detail_id IN NUMBER,
    p_responder_userid  IN VARCHAR2,
    p_action            IN VARCHAR2,
    p_remarks           IN VARCHAR2,
    o_success           OUT NUMBER,
    o_msg               OUT VARCHAR2
) AS
    v_status VARCHAR2(20);
    v_responder_role VARCHAR2(50);
BEGIN
    o_success := 0;


    SELECT UPPER(NVL(r.ROLE_NAME, ''))
      INTO v_responder_role
      FROM USERDETAIL u
      LEFT JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
     WHERE u.USERDETAILID = p_responder_user_detail_id;

    IF v_responder_role <> 'BANK SUPPORT' THEN
        o_msg := 'Access Denied: Only Bank Support users can take action on tickets.';
        RETURN;
    END IF;

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
        RESPONDER_USER_ID, RESPONDER_USERID,
        ACTION_TAKEN, REMARKS
    ) VALUES (
        FN_GET_NEXT_ID('JB_TICKET_RESPONSES_SEQ'), p_ticket_id,
        p_responder_user_detail_id, p_responder_userid,
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
    WHEN NO_DATA_FOUND THEN
        o_msg := 'Responder not found.';
    WHEN OTHERS THEN
        o_success := 0;
        o_msg     := SQLERRM;
END;
/










CREATE OR REPLACE PROCEDURE SP_GET_USER_BY_MOBILE (
    p_mobile   IN VARCHAR2,
    o_cursor   OUT SYS_REFCURSOR
) AS
BEGIN
    OPEN o_cursor FOR
        SELECT u.USERDETAILID,
               u.USERID,
               u.FULLNAME,
               u.MOBILE_NO,
               u.EMAIL,
               u.USERSTATUS,
               u.FAILED_ATTEMPTS,
               u.ROLE_ID,
               NVL(r.ROLE_NAME, 'No Role')
          FROM USERDETAIL u
          LEFT JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
         WHERE TRIM(u.MOBILE_NO) = TRIM(p_mobile)
         ORDER BY u.USERDETAILID DESC;
END;
/

CREATE OR REPLACE PROCEDURE SP_UNLOCK_USER_BY_MOBILE (
    p_mobile               IN  VARCHAR2,
    p_temp_hashed_password IN  VARCHAR2,
    o_userid               OUT VARCHAR2,
    o_email                OUT VARCHAR2,
    o_status               OUT VARCHAR2,
    p_success              OUT NUMBER,
    p_msg                  OUT VARCHAR2
) AS
    v_user_detail_id NUMBER;
BEGIN
    p_success := 0;
    o_userid  := NULL;
    o_email   := NULL;
    o_status  := NULL;

    IF TRIM(NVL(p_mobile, ' ')) IS NULL THEN
        p_msg := 'Mobile number is required.';
        RETURN;
    END IF;

    SELECT USERDETAILID INTO v_user_detail_id
      FROM (SELECT USERDETAILID
              FROM USERDETAIL
             WHERE TRIM(MOBILE_NO) = TRIM(p_mobile)
             ORDER BY USERDETAILID DESC)
     WHERE ROWNUM = 1;

    SELECT USERID, EMAIL INTO o_userid, o_email
      FROM USERDETAIL
     WHERE USERDETAILID = v_user_detail_id;

    IF p_temp_hashed_password IS NULL THEN
        UPDATE USERDETAIL
           SET USERSTATUS      = 'Enabled',
               FAILED_ATTEMPTS = 0
         WHERE USERDETAILID = v_user_detail_id;
    ELSE
        UPDATE USERDETAIL
           SET USERPASSWORD    = p_temp_hashed_password,
               USERSTATUS      = 'Enabled',
               IS_FIRST_LOGIN  = 1,
               FAILED_ATTEMPTS = 0
         WHERE USERDETAILID = v_user_detail_id;
    END IF;

    SELECT USERSTATUS INTO o_status
      FROM USERDETAIL
     WHERE USERDETAILID = v_user_detail_id;

    p_success := 1;
    p_msg     := o_userid || ' has been unlocked.';
    COMMIT;
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        p_success := 0;
        p_msg     := 'No user found with the provided mobile number.';
    WHEN OTHERS THEN
        p_success := 0;
        p_msg     := SQLERRM;
END;
/





CREATE OR REPLACE PROCEDURE SP_GET_ASSIGNABLE_MENUS (
    p_actor_user_id IN NUMBER,
    o_cursor        OUT SYS_REFCURSOR
) AS
BEGIN
    OPEN o_cursor FOR
        SELECT m.MENU_ID, m.MENU_TITLE, m.URL_NAME, NVL(m.ICON_CLASS, '')
          FROM SYSTEM_MENU m
         WHERE m.PARENT_ID IS NULL
           AND ( EXISTS (SELECT 1
                           FROM USER_MENU_ASSIGNMENT uma
                          WHERE uma.USERDETAILID = p_actor_user_id
                            AND uma.MENU_ID = m.MENU_ID)
              OR (NOT EXISTS (SELECT 1
                                FROM USER_MENU_ASSIGNMENT any_uma
                               WHERE any_uma.USERDETAILID = p_actor_user_id)
              AND EXISTS (SELECT 1
                            FROM USERDETAIL u
                            JOIN ROLE_MENU_PERMISSION rmp ON rmp.ROLE_ID = u.ROLE_ID
                           WHERE u.USERDETAILID = p_actor_user_id
                             AND rmp.MENU_ID = m.MENU_ID)) )
      ORDER BY m.DISPLAY_ORDER, m.MENU_TITLE;
END;
/

CREATE OR REPLACE PROCEDURE SP_GET_MENU_ASSIGN_USERS (
    p_actor_user_id IN NUMBER,
    o_cursor        OUT SYS_REFCURSOR
) AS
    v_actor_role VARCHAR2(50);
BEGIN
    SELECT UPPER(NVL(r.ROLE_NAME, ''))
      INTO v_actor_role
      FROM USERDETAIL u
      LEFT JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
     WHERE u.USERDETAILID = p_actor_user_id;

    IF v_actor_role = 'SUPERADMIN' THEN
        OPEN o_cursor FOR
            SELECT u.USERID,
                   u.USERDETAILID,
                   u.FULLNAME,
                   u.EMAIL,
                   u.USERSTATUS,
                   NVL(r.ROLE_NAME, 'No Role'),
                   NVL(u.ROLE_ID, 0),
                   (SELECT LISTAGG(m2.MENU_ID, ',') WITHIN GROUP (ORDER BY m2.DISPLAY_ORDER, m2.MENU_ID)
                      FROM USER_MENU_ASSIGNMENT a
                      JOIN SYSTEM_MENU m2 ON a.MENU_ID = m2.MENU_ID
                     WHERE a.USERDETAILID = u.USERDETAILID
                       AND m2.PARENT_ID IS NULL) AS MENU_IDS,
                   (SELECT LISTAGG(m2.MENU_TITLE, '|') WITHIN GROUP (ORDER BY m2.DISPLAY_ORDER, m2.MENU_ID)
                      FROM USER_MENU_ASSIGNMENT a
                      JOIN SYSTEM_MENU m2 ON a.MENU_ID = m2.MENU_ID
                     WHERE a.USERDETAILID = u.USERDETAILID
                       AND m2.PARENT_ID IS NULL) AS MENU_TITLES
              FROM USERDETAIL u
              LEFT JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
             WHERE u.USERDETAILID <> p_actor_user_id
             ORDER BY u.FULLNAME;
    ELSIF v_actor_role = 'MANAGER' THEN
        OPEN o_cursor FOR
            SELECT u.USERID,
                   u.USERDETAILID,
                   u.FULLNAME,
                   u.EMAIL,
                   u.USERSTATUS,
                   NVL(r.ROLE_NAME, 'No Role'),
                   NVL(u.ROLE_ID, 0),
                   (SELECT LISTAGG(m2.MENU_ID, ',') WITHIN GROUP (ORDER BY m2.DISPLAY_ORDER, m2.MENU_ID)
                      FROM USER_MENU_ASSIGNMENT a
                      JOIN SYSTEM_MENU m2 ON a.MENU_ID = m2.MENU_ID
                     WHERE a.USERDETAILID = u.USERDETAILID
                       AND m2.PARENT_ID IS NULL) AS MENU_IDS,
                   (SELECT LISTAGG(m2.MENU_TITLE, '|') WITHIN GROUP (ORDER BY m2.DISPLAY_ORDER, m2.MENU_ID)
                      FROM USER_MENU_ASSIGNMENT a
                      JOIN SYSTEM_MENU m2 ON a.MENU_ID = m2.MENU_ID
                     WHERE a.USERDETAILID = u.USERDETAILID
                       AND m2.PARENT_ID IS NULL) AS MENU_TITLES
              FROM USERDETAIL u
              LEFT JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
             WHERE UPPER(NVL(r.ROLE_NAME, '')) = 'USER'
             ORDER BY u.FULLNAME;
    ELSE
        OPEN o_cursor FOR
            SELECT CAST(NULL AS VARCHAR2(30)),
                   CAST(NULL AS NUMBER),
                   CAST(NULL AS VARCHAR2(100)),
                   CAST(NULL AS VARCHAR2(100)),
                   CAST(NULL AS VARCHAR2(20)),
                   CAST(NULL AS VARCHAR2(50)),
                   CAST(NULL AS NUMBER),
                   CAST(NULL AS VARCHAR2(4000)),
                   CAST(NULL AS VARCHAR2(4000))
              FROM DUAL
             WHERE 1 = 0;
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        OPEN o_cursor FOR
            SELECT CAST(NULL AS VARCHAR2(30)),
                   CAST(NULL AS NUMBER),
                   CAST(NULL AS VARCHAR2(100)),
                   CAST(NULL AS VARCHAR2(100)),
                   CAST(NULL AS VARCHAR2(20)),
                   CAST(NULL AS VARCHAR2(50)),
                   CAST(NULL AS NUMBER),
                   CAST(NULL AS VARCHAR2(4000)),
                   CAST(NULL AS VARCHAR2(4000))
              FROM DUAL
             WHERE 1 = 0;
END;
/







CREATE OR REPLACE PROCEDURE SP_SET_USER_MENU_ACCESS (
    p_actor_user_id  IN NUMBER,
    p_target_userid  IN VARCHAR2,
    p_menu_id        IN NUMBER,
    p_enable         IN NUMBER,
    p_success        OUT NUMBER,
    p_msg            OUT VARCHAR2
) AS
    v_actor_role      VARCHAR2(50);
    v_target_id       NUMBER;
    v_target_role     VARCHAR2(50) := '';
    v_actor_per_user  NUMBER := 0;
    v_target_per_user NUMBER := 0;
    v_menu_count      NUMBER;
    v_cnt             NUMBER;
    v_menu_title      VARCHAR2(100);
BEGIN
    p_success := 0;

    SELECT UPPER(NVL(r.ROLE_NAME, ''))
      INTO v_actor_role
      FROM USERDETAIL u
      LEFT JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
     WHERE u.USERDETAILID = p_actor_user_id;

    IF v_actor_role NOT IN ('SUPERADMIN', 'MANAGER') THEN
        p_msg := 'Access Denied: Only Superadmin or Manager can change menu access.';
        RETURN;
    END IF;

    BEGIN
        SELECT u.USERDETAILID, UPPER(NVL(r.ROLE_NAME, ''))
          INTO v_target_id, v_target_role
          FROM USERDETAIL u
          LEFT JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
         WHERE u.USERID = p_target_userid;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            p_msg := 'Target user not found.';
            RETURN;
    END;

    IF v_target_id = p_actor_user_id THEN
        p_msg := 'You cannot change your own menu access.';
        RETURN;
    END IF;

    IF v_actor_role = 'MANAGER' AND v_target_role <> 'USER' THEN
        p_msg := 'Access Denied: Managers can only assign menus to regular User accounts.';
        RETURN;
    END IF;

    SELECT MENU_TITLE INTO v_menu_title
      FROM SYSTEM_MENU
     WHERE MENU_ID = p_menu_id;

    SELECT COUNT(1) INTO v_actor_per_user
      FROM USER_MENU_ASSIGNMENT
     WHERE USERDETAILID = p_actor_user_id;

    IF v_actor_per_user > 0 THEN
        SELECT COUNT(1) INTO v_cnt
          FROM USER_MENU_ASSIGNMENT
         WHERE USERDETAILID = p_actor_user_id AND MENU_ID = p_menu_id;
    ELSE
        SELECT COUNT(1) INTO v_cnt
          FROM USERDETAIL u
          JOIN ROLE_MENU_PERMISSION rmp ON rmp.ROLE_ID = u.ROLE_ID
         WHERE u.USERDETAILID = p_actor_user_id
           AND rmp.MENU_ID = p_menu_id;
    END IF;

    IF v_cnt = 0 THEN
        p_msg := 'Access Denied: You may only grant menus that are assigned to you.';
        RETURN;
    END IF;



    SELECT COUNT(1) INTO v_target_per_user
      FROM USER_MENU_ASSIGNMENT
     WHERE USERDETAILID = v_target_id;

    IF v_target_per_user = 0 THEN
        INSERT INTO USER_MENU_ASSIGNMENT (USERDETAILID, MENU_ID, ASSIGNED_BY_USER_ID, ASSIGNED_AT)
        SELECT v_target_id, rmp.MENU_ID, p_actor_user_id, CURRENT_TIMESTAMP
          FROM USERDETAIL u
          JOIN ROLE_MENU_PERMISSION rmp ON rmp.ROLE_ID = u.ROLE_ID
         WHERE u.USERDETAILID = v_target_id;
    END IF;

    SELECT COUNT(1) INTO v_menu_count
      FROM USER_MENU_ASSIGNMENT
     WHERE USERDETAILID = v_target_id AND MENU_ID = p_menu_id;

    IF p_enable = 1 THEN
        IF v_menu_count > 0 THEN
            p_msg := 'Menu already assigned to the user.';
            RETURN;
        END IF;
        INSERT INTO USER_MENU_ASSIGNMENT (USERDETAILID, MENU_ID, ASSIGNED_BY_USER_ID, ASSIGNED_AT)
        VALUES (v_target_id, p_menu_id, p_actor_user_id, CURRENT_TIMESTAMP);
        p_msg := 'Menu "' || v_menu_title || '" assigned to ' || p_target_userid || '.';
    ELSE
        IF v_menu_count = 0 THEN
            p_msg := 'Menu is not assigned to the user.';
            RETURN;
        END IF;
        DELETE FROM USER_MENU_ASSIGNMENT
         WHERE USERDETAILID = v_target_id AND MENU_ID = p_menu_id;
        p_msg := 'Menu "' || v_menu_title || '" removed from ' || p_target_userid || '.';
    END IF;

    p_success := 1;
    COMMIT;
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        p_success := 0;
        p_msg     := 'Menu not found.';
    WHEN OTHERS THEN
        p_success := 0;
        p_msg     := SQLERRM;
END;
/

CREATE OR REPLACE PROCEDURE SP_ASSIGN_BANK_SUPPORT_ROLE (
    p_actor_user_id  IN NUMBER,
    p_target_userid  IN VARCHAR2,
    p_enable         IN NUMBER,
    p_success        OUT NUMBER,
    p_msg            OUT VARCHAR2
) AS
    v_actor_role   VARCHAR2(50);
    v_target_id    NUMBER;
    v_target_role  VARCHAR2(50) := '';
    v_support_role_id NUMBER;
    v_user_role_id NUMBER;
BEGIN
    p_success := 0;

    SELECT UPPER(NVL(r.ROLE_NAME, ''))
      INTO v_actor_role
      FROM USERDETAIL u
      LEFT JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
     WHERE u.USERDETAILID = p_actor_user_id;

    IF v_actor_role <> 'SUPERADMIN' THEN
        p_msg := 'Access Denied: Only Superadmin can assign the Bank Support role.';
        RETURN;
    END IF;

    BEGIN
        SELECT u.USERDETAILID, UPPER(NVL(r.ROLE_NAME, ''))
          INTO v_target_id, v_target_role
          FROM USERDETAIL u
          LEFT JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
         WHERE u.USERID = p_target_userid;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            p_msg := 'Target user not found.';
            RETURN;
    END;

    IF v_target_id = p_actor_user_id THEN
        p_msg := 'You cannot change your own role.';
        RETURN;
    END IF;

    SELECT ROLE_ID INTO v_support_role_id
      FROM SYSTEM_ROLE
     WHERE UPPER(ROLE_NAME) = 'BANK SUPPORT';

    SELECT ROLE_ID INTO v_user_role_id
      FROM SYSTEM_ROLE
     WHERE UPPER(ROLE_NAME) = 'USER';

    IF p_enable = 1 THEN
        IF v_target_role NOT IN ('USER', 'BANK SUPPORT') THEN
            p_msg := 'Only regular users can be made Bank Support.';
            RETURN;
        END IF;
        UPDATE USERDETAIL SET ROLE_ID = v_support_role_id WHERE USERDETAILID = v_target_id;
        p_msg := 'User ' || p_target_userid || ' is now Bank Support.';
    ELSE
        IF v_target_role <> 'BANK SUPPORT' THEN
            p_msg := 'User is not Bank Support.';
            RETURN;
        END IF;
        UPDATE USERDETAIL SET ROLE_ID = v_user_role_id WHERE USERDETAILID = v_target_id;
        p_msg := 'Bank Support role removed from ' || p_target_userid || '.';
    END IF;

    p_success := 1;
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        p_success := 0;
        p_msg     := SQLERRM;
END;
/





