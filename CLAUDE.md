# seablock-translate 项目说明

本项目为 Factorio SeaBlock2 模组包提供简体中文本地化翻译，覆盖 SeaBlock、Angel's 系列及相关模组。

中文翻译文件（`locale/zh-CN/`）是唯一存储在仓库里的 locale 文件，英文参考文件**不**持久化存储，只在 diff 时按需临时拉取后丢弃。

## 目录结构

```
seablock-translate/
├── .gitignore               # 排除 upstream-cache/
├── info.json                # Factorio mod 必须文件
├── mods.lock                # 上游 pin 清单 + 文件映射（提交到仓库）
├── scripts/
│   ├── scan-mods.sh         # 交互式扫描上游仓库，生成 mods.lock
│   ├── check-updates.sh     # 零带宽检测上游是否有新 commit
│   └── diff-upstream.sh     # 按需拉取英文 locale，比较两版本差异后丢弃
├── locale/
│   └── zh-CN/               # 唯一的 locale 文件，提交到仓库（注意：连字符）
└── upstream-cache/          # gitignore - 本地 bare clone 缓存（可重建）
```

## Factorio Mod 格式要求

- **`info.json`**（必须）：包含 `name`、`version`、`title` 字段
- **`locale/<lang>/`**：语言代码用**连字符**，不用下划线（正确：`zh-CN`，错误：`zh_CN`）
- locale 文件必须直接放在 `locale/<lang>/` 下，**不支持子目录**
- 文件格式：UTF-8（无 BOM）的 `.cfg` 文件，`key = value` 格式

## 上游跟踪工作流

### mods.lock 格式

`mods.lock` 锁定每个上游模组到特定 commit hash，并声明文件映射关系。

**一仓库一 mod：**
```json
{
  "schema_version": 1,
  "mods": {
    "seablock-packs": {
      "url": "https://github.com/SpaceMod/SeaBlock-Packs.git",
      "upstream_branch": "master",
      "pinned_sha": "a3f9c2d1...",
      "pinned_at": "2026-02-25",
      "locale_files": [
        { "upstream": "locale/en/seablock.cfg", "local": "seablock.cfg" }
      ]
    }
  }
}
```

**一仓库多 mod（如 Angelmods）：** 每个 Factorio mod 是独立条目，用 `cache_key` 共享同一个 bare clone：
```json
{
  "angelsbioprocessing": {
    "url": "https://github.com/Angelsmods/Angelmods.git",
    "cache_key": "angelmods",
    "upstream_branch": "master",
    "pinned_sha": "a3f9c2d1...",
    "pinned_at": "2026-02-25",
    "locale_files": [
      { "upstream": "angelsbioprocessing/locale/en/bio.cfg", "local": "angelsbioprocessing-bio.cfg" }
    ]
  }
}
```

- `cache_key` 存在时，bare clone 放在 `upstream-cache/<cache_key>.git/`；否则用 mod 名
- 同一 `cache_key` 的条目 `pinned_sha` 应保持一致
- `upstream_only: true`：标记已有完善上游翻译、无需本地维护的 mod（`check-updates.sh` 仍追踪，但 `locale/zh-CN/` 不存储其翻译文件）

### 核心脚本

**`check-updates.sh`** — 零带宽检测变更：
- 用 `git ls-remote` 查询上游当前 branch tip，与 `pinned_sha` 比较
- 不下载任何 git 对象；对同一 URL 只查询一次
- 输出 `[OK]` 或 `[CHANGED]`

**`diff-upstream.sh <mod> <new-sha>`** — 按需拉取，比较后丢弃：
- 确保 bare clone 存在（`--filter=blob:none`）
- fetch 目标 SHA，用 `git show <sha>:path` 输出内容做 diff
- 不在磁盘留下英文文件

**`scan-mods.sh`** — 交互式扫描并生成 mods.lock：
- 读取 `sources.txt`，对每个仓库 `git ls-remote` 获取 SHA，建立临时 bare partial clone
- 列出所有 `locale/en/*.cfg` 路径，提示用户确认本地文件名
- 写入 `mods.lock`

### 升级 pin（手动操作）

```bash
# 1. 查看变更
./scripts/diff-upstream.sh angelspetrochem <new-sha>

# 2. 确认无误后更新 mods.lock
jq ".mods[\"angelspetrochem\"].pinned_sha = \"<new-sha>\" \
  | .mods[\"angelspetrochem\"].pinned_at = \"$(date +%Y-%m-%d)\"" \
  mods.lock > tmp.json && mv tmp.json mods.lock

# 3. 提交
git add mods.lock locale/zh-CN/
git commit -m "chore: upgrade angelspetrochem to <short-sha>"
```

### 依赖

- `git` >= 2.27
- `jq`（解析 mods.lock）
- `diff`（系统自带）

## 翻译文件列表

| 文件 | 内容 |
|------|------|
| `angelsrefining-ore-refining.cfg` | 矿石精炼：机器、矿石类型、设置 |
| `angelsrefining-ore-refining-refining.cfg` | 矿石精炼：中间产品 |
| `angelsrefining-ore-refining-sorting.cfg` | 矿石分选配方 |
| `angelsrefining-water-treatment.cfg` | 水处理 |
| `angelsrefining-tips-and-tricks.cfg` | 精炼提示 |
| `angelsrefining-welcome-message.cfg` | 欢迎信息 |
| `angelsbioprocessing-bio-processing.cfg` | 生物处理：实体、物品、配方、科技 |
| `angelsbioprocessing-tips-and-tricks.cfg` | 生物处理提示 |
| `angelspetrochem-petrochem.cfg` | 石化处理 |
| `angelspetrochem-nuclear-power.cfg` | 核能 |
| `angelspetrochem-tips-and-tricks.cfg` | 石化提示 |
| `angelssmelting.cfg` | 冶炼与铸造 |
| `angelsaddons-storage.cfg` | 仓储附加包 |
| `angelsaddons-storage-tips-and-tricks.cfg` | 仓储提示 |
| `reskins-angels.cfg` | 工匠重绘：天使系列 |
| `reskins-bobs.cfg` | 工匠重绘：鲍氏系列 |
| `CircuitProcessing.cfg` | 电路板处理 |
| `LandfillPainting.cfg` | 填土涂装 |
| `SeaBlock.cfg` | SeaBlock 专属内容 |
| `SpaceMod.cfg` | 太空模组 |
| `sciencecosttweaker.cfg` | 科研费用调整 |

## 翻译规范

### 文件格式

- 保留 `[section]` 区块头
- 保留 `;` 注释行，只翻译 `key=value` 中的 value 部分
- 保留所有占位符：`__1__`、`__ENTITY__xxx__`、`__ITEM__xxx__`
- 保留换行符 `\n`（不转换为实际换行）
- 富文本标签处理规则：
  - `[img=...]`、`[item=...]`、`[fluid=...]`、`[entity=...]` — **完整保留，不翻译**
  - `[font=...]...[/font]`、`[color=...]...[/color]` — **标签原样保留，内部文字需翻译**
  - `[tooltip=显示文字,引用键]` — **显示文字需翻译，逗号后的引用键不动**

### 关键术语表

#### 六种复合矿石

| 英文 | 中文 | 备注 |
|------|------|------|
| Saphirite | 碧铁矿 | 蓝色；主产铁；Sapphire 词根，碧避开真实矿物蓝铁矿(Vivianite) |
| Jivolite | 辉铁矿 | 黄色；主产铁；幻想词根，辉=矿物光泽，避开黄铁矿(Pyrite) |
| Stiratite | 纹铜矿 | 蓝色条纹；主产铜；词根含 stria(条纹)，避开赤铜矿(Cuprite) |
| Crotinnium | 霜铜矿 | 白色；主产铜；-ium 金属后缀，霜对应白色外观，避开白铜(cupronickel) |
| Rubyte | 绯铅矿 | 红色；主产铅（仅 bobplates）；Ruby 词根，绯=深红，避开红铅矿(Crocoite) |
| Bobmonium | 鲍氏矿 | 棕色；主产锡（仅 bobplates）；致敬 Bob's Mods 作者 |

#### 矿石精炼产品

| 英文 | 中文 | 备注 |
|------|------|------|
| Crushed ore | 粉碎矿石 | 粉碎机产出 |
| Ore chunk | 矿石块 | 浮选后产物 |
| Ore crystal | 矿石晶体 | 酸浸后产物 |
| Purified ore | 纯化矿石 | 热力精炼后产物 |
| Nugget | 矿粒 | 小碎粒副产物 |
| Pellet | 球团矿 | 冶炼用中间品 |
| Ingot | 锭 | 格式：×锭，如铁锭 |
| Geode | 晶洞石 | 浮选副产品 |
| Slag | 矿渣 | |
| Mineral sludge | 矿物污泥 | |

#### 精炼工艺流程

| 英文 | 中文 | 备注 |
|------|------|------|
| Crushing / Ore crushing | 粉碎 | |
| Flotation / Hydro-refining | 浮选 | 化工工序 |
| Leaching / Chemical refining | 酸浸 | |
| Thermal refining | 热力精炼 | |
| Electrowinning | 电解沉积 | |
| Electrolysis | 电解 | |
| Crystallization | 结晶 | |
| Purification | 纯化 | |
| Ore sorting | 矿石分选 | |
| Casting | 铸造 | |
| Smelting | 冶炼 | 专指冶金流程，与 Factorio 基础"熔炼"区分 |

#### 设备与建筑

**矿石处理链**

| 英文 | 中文 |
|------|------|
| Ore crusher / Burner ore crusher | 矿石粉碎机 |
| Flotation cell | 浮选槽 |
| Leaching plant | 酸浸厂 |
| Ore refinery | 矿石精炼炉 |
| Electrowinning cell | 电解沉积槽 |
| Electrolyser | 电解槽 |
| Crystallizer | 结晶器 |
| Ore sorting facility | 矿石分选设施 |
| Filtration unit | 过滤装置 |
| Milling drum | 研磨滚筒 |

**冶金设备**

| 英文 | 中文 |
|------|------|
| Blast furnace | 高炉 |
| Chemical furnace | 化学炉 |
| Induction furnace | 感应炉 |
| Casting machine | 铸造机 |
| Strand casting machine | 连铸机 |
| Pellet press | 造球机 |
| Filtering furnace | 过滤炉 |

**水处理与生物链**

| 英文 | 中文 |
|------|------|
| Hydro plant | 水处理厂 |
| Clarifier | 澄清器 |
| Composter | 堆肥机 |
| Bioprocessor | 生物处理器 |
| Arboretum | 植物园 |
| Butchery | 屠宰场 |
| Hatchery | 孵化场 |
| Refugium | 庇护所 |
| Algae farm | 藻类养殖场 |
| Seed extractor | 种子提取机 |
| Nutrient extractor | 营养提取机 |
| Oil press | 榨油机 |
| Silo | 筒仓 |
| Bore / Thermal bore | 热力钻探机 |
| Thermal extractor | 热力提取机 |

#### 流体

| 英文 | 中文 |
|------|------|
| Purified water | 净化水 |
| Saline water | 盐水 |
| Mineralized water | 矿化水 |
| Thermal water | 热矿物质水 |
| Wastewater / Waste water | 废水 |
| Sulfuric waste water | 硫酸废水 |
| Fluoric waste water | 氢氟酸废水 |
| Chloric waste water | 盐酸废水 |
| Nitric waste water | 硝酸废水 |

#### 材料与中间产品

| 英文 | 中文 | 备注 |
|------|------|------|
| Charcoal | 木炭 | |
| Charcoal filter | 木炭过滤器 | |
| Charcoal pellet | 木炭颗粒 | |
| Ceramic filter | 陶瓷过滤器 | |
| Coke / Solid coke | 焦炭 | |
| Limestone | 石灰石 | |
| Coolant | 冷却液 | |
| Catalyst / Catalysator | 催化剂 | |
| Nutrient | 营养素 | |
| Basic circuit board | 基础电路板 | |
| Electrode | 电极 | |
| Mold | 铸模 | |

#### 通用术语

| 英文 | 中文 | 备注 |
|------|------|------|
| Nauvis | 新地星 | Factorio 官方译名，勿译为"诺维斯" |
| Biters | 虫族 | Factorio 官方译名 |
| Puffer | 膨鱼 | 生物处理生物 |
| Warehouse | 仓库 | |
| Landfill | 填土 | |
| Circuit network | 电路网络 | |
| Logistic network | 物流网络 | |
| Exoplanetary Studies Lab | 系外行星研究中心 | |
| Faster than light | 超光速 | |

### 不翻译的内容

- 外星植物名（Wheaton、Tianaton、Okarinome、Quillnoa、Kendallion 等）——为虚构名称，无标准中文译名
- 模组名中的专有缩写（ATMOS、VP、QL 等）

### 分级物品命名规范

Bob's/Angel's 系列模组中，大量物品和建筑存在多个等级。统一采用以下规则：

**规则：MK 格式（适用于物品名和建筑名）**

| 等级 | 格式 | 示例 |
|------|------|------|
| 第 1 级 | 无后缀 | `高炉`、`机器人充电站` |
| 第 2 级起 | ` MK2`、` MK3`…… | `高炉 MK2`、`机器人充电站 MK3` |

**例外：组装机系列**（`assembling-machine`）沿用原版中文惯例，格式为 `组装机4型`、`组装机5型`，不使用 MK。

**不适用的场景（不改，保持原样）：**
- `[recipe-name]` 配方名中的等级编号
- `[technology-name]` 科技名中的等级编号

### 风格指南

- 物品/配方名：简洁名词短语，去掉不必要的冠词（如 "a"、"the"）
- 描述文本：自然流畅的中文，不逐字直译，避免机器翻译腔
- 技术术语优先对应现实化工/冶金术语（参照 GregTech/IC2 中文社区惯例）
- 遇到不确定的专有名词：查阅术语表；没有的，语境意译后在文件末尾用 `; TODO: 以下术语待确认` 注明

## 待办事项

- [ ] 补全 `mods.lock`：查阅 `upstream-cache/` 中 `seablock-meta` 的 `info.json`，确认其依赖链，再相应更新 `info.json` 的 `dependencies`
- [ ] 编写 `scripts/check-updates.sh`
- [ ] 编写 `scripts/diff-upstream.sh`
- [ ] 编写 `scripts/scan-mods.sh`
- [ ] 补全 `.gitignore`（排除 `upstream-cache/`）

## 提交规范

按模组类型分组提交，格式：
```
feat(locale): add zh-CN translations for <ModName> mod
```
