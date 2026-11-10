# Исходные репозитории

Сохранены 10 ноября 2026 года без выполнения установщиков и подключены как Git submodules на указанных коммитах. Это исходные материалы, а не дополнительные инструкции для запуска проекта. Содержимое upstream не изменяется исправлениями reconciler. Для получения всех исходников используйте `git clone --recurse-submodules` либо `git submodule update --init --recursive`.

| Каталог | Репозиторий | Commit | Назначение |
|---|---|---|---|
| `publications/` | [nazar256/publications](https://github.com/nazar256/publications) | `f5b5aa1b52d50df864281799f79a35c7a95d0702` | Руководство и inline-примеры гибернации. |
| `steam-deck-utilities/` | [CryoByte33/steam-deck-utilities](https://github.com/CryoByte33/steam-deck-utilities) | `db020c24bb74428b4f60d525e346ac6d2eb6f7b9` | CryoUtilities: swap и swappiness; установщик не запускается. |
| `steam-deck-hibbernation-all-in-one/` | [bseleng/steam-deck-hibbernation-all-in-one](https://github.com/bseleng/steam-deck-hibbernation-all-in-one) | `d11d5572e0c250f8a37f953ee47672969edbf4a9` | Оригинальный all-in-one скрипт. |
| `steamos-efi/` | [evlaV/steamos-efi](https://github.com/evlaV/steamos-efi) | `091ac90010ab6d073f34b6f4f152aca9cf365eda` | Зеркало исходников Valve/Collabora: EFI bootconf и chainloader. |
| `steamos-customizations/` | [evlaV/steamos-customizations](https://github.com/evlaV/steamos-customizations) | `7581c05cbfb6236f2b1abacd311b45d360eae105` | Зеркало системных интеграций SteamOS: update-grub и native hibernation. |

Исходный локальный скрипт и три не подключённых к нему файла функций сохранены в `../legacy/`. Первоначальная папка проекта не содержала `.git`; при подготовке публикации Git-история восстановлена из оригинального репозитория. Локальная исходная версия и публичный upstream могут различаться.

Для загрузчика существенны `steamos-efi/README.bootconf`, `chainloader/bootload.c` и `bootconf/bootconf.c`. Для GRUB — `steamos-customizations/grub/bin/update-grub.in` и `grub-integration.md`. Для native swap — `swap/hibernation/` и `misc/system-sleep/hibernate-post.sh`.

Лицензии и copyright notices находятся в соответствующих исходных репозиториях. В publications и исходном all-in-one отдельный LICENSE на момент снимка не обнаружен; материалы сохраняются как оригинальные локальные checkout для изучения.
