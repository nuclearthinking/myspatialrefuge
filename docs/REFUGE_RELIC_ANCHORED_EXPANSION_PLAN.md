# Relic-Anchored Refuge Expansion

## Цель

Убежище на каждом уровне остаётся квадратом прежнего размера. Положение реликвии перед расширением определяет, какая точка квадрата остаётся физически неподвижной:

- центр — обычное симметричное расширение;
- один из четырёх изометрических углов — две сходящиеся в нём стороны остаются на месте, две противоположные стороны получают весь прирост.

Неизменные `centerX/centerY` обозначают центр выделенного слота. Геометрический центр текущего убежища вычисляется как `center + areaOffset`. Сохраняются только `areaOffsetX` и `areaOffsetY`; при отсутствии полей они равны нулю.

## Геометрический контракт

Shared-модуль `MSR_RefugeGeometry.lua` является единственным источником effective bounds:

- `GetAreaCenter(refugeData)`;
- `GetTileBounds(refugeData)`;
- `GetWallBounds(refugeData)`;
- `ContainsTile(refugeData, x, y)`;
- `ValidateAnchor(dx, dy, name)`;
- `InferAnchor(refugeData, relicX, relicY)`;
- `GetRelicTarget(refugeData, anchor)`;
- `PlanExpansion(refugeData, newRadius, anchor)`;
- `GetSlotKey(refugeData)`;
- `GetMaximumDirectionalExtent()`.

Формула перехода:

```text
delta = newRadius - oldRadius
newOffsetX = oldOffsetX - anchor.dx * delta
newOffsetY = oldOffsetY - anchor.dy * delta
```

Допустимы только канонические `Center`, `Up`, `Right`, `Left`, `Down` и соответствующие им пары смещений. Сервер выводит anchor из фактического тайла реликвии перед каждым расширением. Промежуточное положение блокирует расширение, пока игрок не переместит реликвию в центр или угол.

Максимальная направленная протяжённость вычисляется из tier-конфигурации. Для радиусов 1…9 она равна 18 тайлам с учётом внешней линии стены и должна оставаться меньше половины `REFUGE_SPACING`.

## Persisted data и миграция

- `CURRENT_DATA_VERSION = 8`.
- Миграция v7→v8 устанавливает `areaOffsetX = 0`, `areaOffsetY = 0` без перемещения объектов.
- Новый save создаётся с нулевыми offset.
- Сериализация authoritative snapshot включает оба offset.
- Старые, offline и orphan-записи читаются с нулевыми offset до миграции владельца.
- Inheritance сохраняет текущие offsets.
- Allocation, decay и slot reuse продолжают адресовать слот по неизменным `centerX/centerY`.

## Системы, зависящие от границ

Чек-лист потребителей effective geometry:

- [x] точный поиск убежища по координатам;
- [x] membership игрока и boundary clamp;
- [x] вход, телепорт и подготовка чанков;
- [x] поиск, перемещение, integrity и recovery реликвии;
- [x] верхние стены и проверка их целостности;
- [x] комнаты, cutaway и локальные bounds-кэши;
- [x] очистка деревьев, зомби и связанных объектов;
- [x] Spatial Well;
- [x] Fertile Resonance через точный lookup;
- [x] генерация подвала, лестницы и chunk checks;
- [x] зеркальные X/Y bounds подвала;
- [x] decay, reclamation и повторное использование слота;
- [x] административная диагностика слота и effective center.

Операции, которые намеренно остаются привязаны к immutable slot center:

- allocation и проверка занятости глобальной сетки;
- slot key и принятие legacy-стен;
- фиксированный envelope reconciliation;
- reclamation и возврат слота в пул;
- проверка отсутствия пересечения соседних слотов.

## Authoritative upgrade coordinator

SP и MP используют один порядок:

```text
validate → prepare → consumeWithReceipt → commit → reconcile → respond
```

Контракт handler:

- `validate(player, level)` — только чтение и проверки;
- `prepare(player, level)` — отдельный immutable candidate/operation;
- `commit(player, level, candidate)` — сохранение authoritative state;
- `reconcile(player, level, candidate)` — идемпотентное применение мира;
- `getResponseData`, `onSuccess`, `invalidatesCache` — представление ответа и UI.

Точные IDs предметов, их типы, количество и substitutions повторно проверяются сервером по серверному рецепту. `consumeWithReceipt` сначала разрешает все объекты и контейнеры, затем удаляет предметы. Частичная ошибка возвращает предметы в исходный контейнер, затем в основной inventory, затем на квадрат игрока.

Если commit не сохранил state, receipt возвращается. После commit расход финализирован; ошибка мира восстанавливается только roll-forward. Persisted journal не используется: аварийное завершение процесса между consumption и commit остаётся принятой редкой границей отказа.

## Boundary reconciliation

`MSR_BoundaryReconciler` выполняется только в authoritative среде и:

1. строит deterministic expected set для effective bounds;
2. сканирует фиксированный envelope immutable слота;
3. принимает актуальные legacy boundary objects без slot key;
4. помечает их `refugeSlotKey`;
5. удаляет obsolete и duplicate стены своего слота;
6. создаёт недостающие стены;
7. безопасно повторяется после частичной генерации.

Клиент не удаляет и не создаёт стены после MP-апгрейда. После commit выполняется немедленная reconciliation и один bounded deferred retry. Дальнейший repair выполняют entry/integrity paths при загрузке чанков, без постоянного tick-handler.

Подвал использует тот же effective center и те же X/Y bounds, что и верхний квадрат. Собственного offset у него нет.

## Игровая подсказка

Tooltip показывается только на родительском пункте `Move Relic`:

- RU: `Пространство убежища откликается на положение реликвии.`
- EN: `The refuge's space responds to the relic's position.`

Эквивалентные строки присутствуют для CN, ES и PTBR в 42.14 `.txt` и 42.15+ `.json`. В окне расширения и повторяющихся сообщениях подсказки нет.

## Матрица самопроверки

### Pure geometry

- [x] offset `0/0` воспроизводит прежние tile bounds;
- [x] пять anchors проходят переходы radius 1→9;
- [x] повтор одного угла сохраняет его физический тайл;
- [x] смешанная последовательность накапливает, а не сбрасывает смещение;
- [x] каждый результат — квадрат 3×3…19×19;
- [x] wall bounds остаются внутри slot envelope;
- [x] directional extent берётся из tier-конфигурации, без `maxRadius = 10`.

### Сохранения

- [ ] новый save;
- [ ] v7 save и миграция без физического перемещения;
- [ ] offline/orphan refuge до входа владельца;
- [ ] inheritance с сохранением offsets;
- [ ] slot reuse после decay;
- [ ] reload сохраняет offsets, реликвию, стены и зеркальный подвал.

### Отказы и транзакции

- [ ] отсутствующая реликвия и bounded recovery;
- [ ] реликвия не на канонической точке;
- [ ] неполный upper/basement envelope чанков;
- [ ] поддельные или неверные MP item IDs;
- [ ] неверные типы, количество и substitutions;
- [ ] partial consumption с возвратом;
- [ ] save failure с возвратом receipt;
- [ ] partial wall generation с повторным repair;
- [ ] duplicate request и повторный response;
- [ ] disconnect/reconnect и late join получают authoritative snapshot.

### Gameplay

- [ ] boundary clamp на всех крайних смещениях;
- [ ] вход/выход и stranded recovery;
- [ ] комнаты и cutaway после нескольких смешанных расширений;
- [ ] Spatial Well и Fertile Resonance у смещённой границы;
- [ ] очистка деревьев/зомби и decay;
- [ ] два MP-убежища расширяются независимо;
- [ ] legacy стены принимаются по slot key;
- [ ] подвал и лестницы являются точным зеркалом верхней геометрии.

### Совместимость и релиз

- [x] `check-pz-lua.ps1` с зафиксированным сравнением baseline: новых диагностик в feature-файлах нет; остаются 19 прежних ошибок неполных PZ API-stubs;
- [ ] runtime smoke для 42.14 требует установленного бинарника игры 42.14; `pzmod --version` выбирает marker версии мода, а не layout;
- [x] `pzmod dev smoke` на установленной 42.20 с layout 42.15+: сервер стартовал, мод загружен, связанных ошибок нет;
- [ ] ручной SP на 42.14, 42.15 и 42.20 с `-debug`;
- [ ] ручной co-op и dedicated server;
- [ ] один non-merge feature commit без `modversion` и `CHANGELOG.yaml`;
- [ ] после commit — `pzmod release inspect --fetch --json`;
- [ ] версия выбирается на release planning вместе с другими eligible features.

Player-facing changelog при включении feature в релиз:

```text
Added: The direction of refuge expansion now responds to the Sacred Relic's position.
```

Полный релиз выполняется только через `pzmod`; отдельные подтверждения обязательны перед заменой release-ветки, merge PR и публичной загрузкой Workshop.
