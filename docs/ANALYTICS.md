# Website visitor statistics / 网站访问统计

Statistics are viewed in your own **Google Analytics 4 management dashboard**, not published on the ModelDock website. The homepage and both illustrated guides share one measurement configuration. The Mac application does not load this website analytics tag.

Collection is enabled when the production deployment has a valid **GA4_MEASUREMENT_ID** repository variable. Local previews keep collection disabled. Earlier traffic cannot be reconstructed from the browser integration.

## Create the property

1. Open [Google Analytics](https://analytics.google.com/), sign in with your Google account, and choose **Start measuring** (or **Admin → Create → Account/Property**).
2. Name the property **ModelDock** and choose the reporting time zone **Asia/Shanghai**. The website configuration documents this choice; the actual reporting time zone must be selected in the GA4 property.
3. Create a **Web** data stream with website address **https://etongle.github.io/ModelDock/**.
4. Copy the **Measurement ID**, beginning with **G-**. It is not the numeric property ID, stream ID, or an API secret. See [Google's setup guide](https://support.google.com/analytics/answer/14183469) and [measurement ID instructions](https://support.google.com/analytics/answer/12270356).

## Enable collection

Set the repository Actions variable **GA4_MEASUREMENT_ID** to that ID at **Repository → Settings → Secrets and variables → Actions → Variables**. Then run **Publish documentation website** in Actions, or push a website change.

The Pages workflow generates `website/analytics-config.json`. This measurement ID is public website configuration, not an account credential. No Google login, API secret, or report-reading credential is embedded. Leaving the variable unset keeps collection disabled. Removing it and redeploying disables the tag.

The tag measures only the production `etongle.github.io/ModelDock/` website, sends one automatic pageview per page load, strips URL query/fragment parameters from the configured page location, and disables advertising personalization and Google Signals. It does not request browser GPS access. Local previews and automated local tests do not send visits to Google.

Check **Realtime** after enabling. Standard reports can take time to process. Browser blocking and unavailable geographic data may reduce or leave gaps in the observed statistics.

## Reports to configure

| Need | GA4 dimensions | Metrics |
| --- | --- | --- |
| Total for the selected date range | No geographic/time grouping | Views, total users, sessions |
| Countries and regions | Country, Region (optionally City) | Views, total users, sessions |
| Daily totals | Date | Views, total users, sessions |
| Hourly time slots | Date + Hour, or Date hour | Views, sessions |

Use **Explore → Free form** to add these dimensions/metrics and select a date range. Add Country/Region as rows for geography, Date as rows for daily trends, and Date hour for an hourly table. Use a separate total report for the entire selected range. Unique-user values across days or countries must not be summed to produce a distinct-user grand total.

See [Google's geography report](https://support.google.com/analytics/answer/12948931) and [official dimensions/metrics](https://developers.google.com/analytics/devguides/reporting/data/v1/api-schema).

## 中文步骤

统计仅在你的 GA4 管理后台查看。先使用自己的 Google 账号创建 **ModelDock** 媒体资源，时区选择 **Asia/Shanghai**；新增网站数据流，网址填 **https://etongle.github.io/ModelDock/**，复制 **G- 开头的测量 ID**。

将 ID 发给项目维护者，或填入仓库 Actions 的 **GA4_MEASUREMENT_ID** 变量后重新运行网站发布。生产网站使用已配置的测量 ID；未配置时和本地预览均关闭统计。

在 GA4 的“探索 → 自由形式”中配置国家、省/州、日期、小时等维度，查看浏览量、用户数和会话数。总量用所选日期范围的整体结果；独立访客不能把每天或每个地区的数据直接相加。统计从启用后开始，无法恢复此前的访问历史。
