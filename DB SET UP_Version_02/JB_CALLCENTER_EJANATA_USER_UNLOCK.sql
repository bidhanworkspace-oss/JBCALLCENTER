
WHENEVER SQLERROR CONTINUE
/

DECLARE
    v_id NUMBER;
BEGIN
    BEGIN
        SELECT MENU_ID INTO v_id
          FROM SYSTEM_MENU
         WHERE URL_NAME = 'ejanata_user_unlock';
    EXCEPTION WHEN NO_DATA_FOUND THEN
        INSERT INTO SYSTEM_MENU (MENU_TITLE, URL_NAME, PARENT_ID, ICON_CLASS, DISPLAY_ORDER)
        VALUES ('eJanata User Unlock', 'ejanata_user_unlock', NULL, 'bi-unlock', 14);
    END;

    COMMIT;
END;
/

DECLARE
    v_menu_id NUMBER;
BEGIN
    SELECT MENU_ID INTO v_menu_id
      FROM SYSTEM_MENU
     WHERE URL_NAME = 'ejanata_user_unlock';

    INSERT INTO ROLE_MENU_PERMISSION (ROLE_ID, MENU_ID)
    SELECT p.ROLE_ID, v_menu_id
      FROM ROLE_MENU_PERMISSION p
      JOIN SYSTEM_MENU m ON m.MENU_ID = p.MENU_ID
     WHERE m.URL_NAME = 'user_unlock'
       AND NOT EXISTS (SELECT 1 FROM ROLE_MENU_PERMISSION x
                        WHERE x.ROLE_ID = p.ROLE_ID
                          AND x.MENU_ID = v_menu_id);

    COMMIT;
END;
/

DECLARE
    v_menu_id NUMBER;
BEGIN
    SELECT MENU_ID INTO v_menu_id
      FROM SYSTEM_MENU
     WHERE URL_NAME = 'ejanata_user_unlock';

    INSERT INTO USER_MENU_ASSIGNMENT (USERDETAILID, MENU_ID, ASSIGNED_BY_USER_ID, ASSIGNED_AT)
    SELECT a.USERDETAILID, v_menu_id, NULL, CURRENT_TIMESTAMP
      FROM USER_MENU_ASSIGNMENT a
      JOIN SYSTEM_MENU m ON m.MENU_ID = a.MENU_ID
     WHERE m.URL_NAME = 'user_unlock'
       AND NOT EXISTS (SELECT 1 FROM USER_MENU_ASSIGNMENT x
                        WHERE x.USERDETAILID = a.USERDETAILID
                          AND x.MENU_ID = v_menu_id);

    COMMIT;
END;
/

COMMIT;

