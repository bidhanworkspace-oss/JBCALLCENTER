
import pathlib
import re

from django.apps import apps
from django.core.checks import Warning, register
from django.db import connections

CALLPROC_NAME = re.compile(r"""callproc\(\s*['"]([A-Za-z0-9_]+)['"]""")

HINT = (
    'Run the CREATE OR REPLACE PROCEDURE statements in database/ as the '
    'application schema user (JBCALLCENTER), then confirm with: '
    "SELECT object_name, status FROM user_objects WHERE object_name = '%s'."
)


def referenced_procedures():
    names = set()
    for app_config in apps.get_app_configs():
        for module in pathlib.Path(app_config.path).rglob('*.py'):
            parts = module.parts
            if '__pycache__' in parts or 'migrations' in parts:
                continue
            if module.name in ('checks.py', 'tests.py'):
                continue
            text = module.read_text(encoding='utf-8', errors='ignore')
            names.update(CALLPROC_NAME.findall(text))
    return sorted(n for n in names if n.upper().startswith('SP_'))


@register()
def stored_procedures_deployed(app_configs, **kwargs):
    names = referenced_procedures()
    if not names:
        return []

    alias = 'default'
    try:
        with connections[alias].cursor() as cursor:
            cursor.execute(
                "SELECT object_name, status FROM user_objects "
                "WHERE object_type = 'PROCEDURE' AND object_name IN (%s)"
                % ', '.join(['%s'] * len(names)),
                names,
            )
            found = {row[0]: row[1] for row in cursor.fetchall()}
    except Exception:
        return []

    issues = []
    for name in names:
        status = found.get(name)
        if status is None:
            issues.append(Warning(
                'Stored procedure %s is missing from the %s schema, so every '
                'screen that calls it fails at runtime.' % (name, connections[alias].settings_dict.get('USER', alias)),
                hint=HINT % name,
                id='login.E001',
            ))
        elif status != 'VALID':
            issues.append(Warning(
                'Stored procedure %s is %s and cannot be called; recompile it.'
                % (name, status),
                hint=HINT % name,
                id='login.E002',
            ))
    return issues
