"""Создание администратора: python manage.py create-admin [--demo]."""
import sys,getpass
from werkzeug.security import generate_password_hash
from app import connect
if __name__=='__main__':
    if len(sys.argv)<2 or sys.argv[1]!='create-admin':
        raise SystemExit('Использование: python manage.py create-admin [--demo]')
    demo='--demo' in sys.argv
    login='admin' if demo else input('Логин: ').strip()
    password='HospitalDemo2026!' if demo else getpass.getpass('Пароль (не менее 8 символов): ')
    if not login or len(password)<8: raise SystemExit('Некорректный логин или короткий пароль')
    with connect() as c:
        c.execute("INSERT INTO account(login,password_hash,role) VALUES (%s,%s,'администратор')",(login,generate_password_hash(password)))
    print('Администратор создан. Демонстрационный режим.' if demo else 'Администратор создан.')
