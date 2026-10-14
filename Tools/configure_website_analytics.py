"""Generate the public GA4 measurement configuration during Pages deployment."""
import json
import os
from pathlib import Path
import re


def configuration(measurement_id):
    value = measurement_id.strip()
    if value and not re.fullmatch(r'G-[A-Z0-9]{6,32}', value):
        raise ValueError('GA4_MEASUREMENT_ID must be a G- measurement ID')
    return {'provider': 'ga4', 'enabled': bool(value), 'measurementId': value,
            'hostname': 'etongle.github.io', 'pathPrefix': '/ModelDock/', 'reportingTimeZone': 'Asia/Shanghai'}


if __name__ == '__main__':
    config = configuration(os.environ.get('GA4_MEASUREMENT_ID', ''))
    target = Path(__file__).resolve().parents[1] / 'website/analytics-config.json'
    target.write_text(json.dumps(config, indent=2) + '\n')
    print('Website analytics: ' + ('enabled' if config['enabled'] else 'waiting for GA4 measurement ID'))
