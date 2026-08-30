    rec=r.get(ip) or {}
n=(rec.get('autonomous_system_number')
   or rec.get('as_number')
   or rec.get('asn')
   or (rec.get('traits') or {}).get('autonomous_system_number'))
org=(rec.get('autonomous_system_organization')
     or rec.get('as_organization')
     or (rec.get('traits') or {}).get('autonomous_system_organization')
     or '')
if n:
    s=str(n)
    if s.upper().startswith('AS'): asn=s.upper()
    else: asn='AS'+s
    print(f'  PASS  {asn}  {org}')
else:
    print('  WARN  Для этого IP ASN не найден')
    print('  Ключи записи: '+', '.join(sorted(rec.keys())))
PYASN
  fi
  echo
  echo 'Источник: DB-IP Lite (CC BY 4.0), базы хранятся только на этом сервере.'
}
