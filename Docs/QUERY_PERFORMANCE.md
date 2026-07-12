# PostgreSQL Message Query Evidence

Measured on 2026-07-12 with PostgreSQL 18.4 in a temporary database. The fixture contains
50,000 `couple` messages and 10,000 `ai:xu` messages. Run it again with:

```powershell
cd server
npm run perf:queries
```

| Query | Plan | Index | Execution |
|---|---|---|---:|
| bootstrap latest 40 | Limit -> Index Scan | `messages_channel_ts_idx` | 0.025 ms |
| before page 300 | Limit -> Index Scan | `messages_channel_ts_idx` | 0.047 ms |
| around, older half | Limit -> Index Scan | `messages_channel_ts_idx` | 0.036 ms |
| around, newer half | Limit -> Index Scan | `messages_channel_ts_idx` | 0.033 ms |
| search `%性能关键字%` | Limit -> Sort -> Seq Scan | none | 4.787 ms |

No migration was added. Timeline queries already use the channel/timestamp index. The text
search scan remains below 5 ms at 50,000 rows, which is comfortably inside the script's
100 ms evidence threshold for this two-account product. A trigram or full-text index would
add migration and write overhead without a measured need.
