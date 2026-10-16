# Политика конфиденциальности / Privacy policy

Приложение «Электрички» (Russian Trains) для часов Garmin.
Действует с 16 октября 2026 года.

## Коротко

Приложение не собирает личные данные: нет аккаунтов, аналитики, рекламы и
геолокации. Чтобы получить расписание, оно отправляет только названия двух
станций из настроек и дату.

## Какие данные передаются

- **Названия станций «Дом» и «Работа»** — как вы их вписали в настройках, и
  **дата**, на которую нужно расписание. Часы передают их через приложение
  Garmin Connect на телефоне на сервер приложения (прокси на Cloudflare
  Workers, исходный код — в папке [`proxy/`](proxy/)).
- Прокси запрашивает расписание у API Яндекс.Расписаний. Яндексу уходят коды
  станций и дата. Ваш IP-адрес и другие данные о вас Яндексу не передаются:
  запрос делает сервер.
- Как и любой веб-сервер, Cloudflare видит IP-адрес телефона, с которого пришёл
  запрос. Прокси его не записывает и не хранит.

## Что хранится

- **На часах:** настройки и расписание на 3 дня.
- **На сервере:** готовое расписание для пары станций на день, до 3 дней, общее
  для всех пользователей. Оно не связано ни с кем лично. Журналы сервера
  содержат только ошибки обращения к Яндексу, без данных о пользователях.

## Третьи стороны

- [Garmin](https://www.garmin.com/privacy/) — передача данных между часами и
  телефоном и настройки приложения в Garmin Connect.
- [Cloudflare](https://www.cloudflare.com/privacypolicy/) — хостинг прокси.
- [Яндекс.Расписания](https://yandex.ru/legal/rasp_api/) — источник
  расписания.

## Контакты

Вопросы — в [issues на GitHub](https://github.com/andreiyurik/garmin-russia-trains/issues).

---

## In short (English)

The app collects no personal data: no accounts, analytics, ads or location.
To get the schedule it sends only the names of the two stations from its
settings and a date. They go from the watch, through the Garmin Connect app
on the phone, to the app's server (a Cloudflare Worker, source in
[`proxy/`](proxy/)). The server asks the Yandex Rasp API for that schedule
using station codes and the date. Nothing about you goes to Yandex, because
the server sends the request.

Cloudflare sees the phone's IP address, as any web server does; the proxy
does not log or store it. The watch keeps the settings and 3 days of
schedule. The server keeps finished schedules for a station pair and day for
up to 3 days. They are shared by all users and not linked to anyone. Server
logs hold only errors from Yandex, no user data.

Questions: [GitHub issues](https://github.com/andreiyurik/garmin-russia-trains/issues).
