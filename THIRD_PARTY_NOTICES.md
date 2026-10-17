# Third-party data and services

The MIT license covers original Earth Pro application code and original app artwork. It does not grant rights to third-party map content, trademarks, datasets, or services. This repository does not contain Google Earth Pro binaries or Google map tiles.

## Commercial-use boundary

Earth Pro's original application code and original artwork are open source under the MIT License. The MIT License permits commercial use of that code; it does not license third-party datasets, imagery, APIs, or services.

The distributed app's included data/service configuration is not cleared for commercial use as-is. In particular, its online elevation feature uses Open-Meteo's free API, whose terms permit only noncommercial use. Do not use that free endpoint for commercial purposes. Commercial deployments must replace or properly license restricted services and review the rights for every enabled dataset, imagery source, custom connection, export, screenshot, and recording. A provider subscription or API key alone does not waive other providers' restrictions. The stock app does not provide a commercial Open-Meteo endpoint/key setting; a compliant alternative requires an adapted build or service configuration.

This is a notice about third-party rights, not an added restriction on MIT-licensed code. Some sources permit commercial use, including public-domain datasets; others impose service, attribution, redistribution, or other conditions. Public access, a free download, or inclusion in a catalog does not establish permission for commercial reuse. No blanket commercial-content license is provided by Earth Pro.

Provider terms checked October 17, 2026:
Open-Meteo free API terms: https://open-meteo.com/en/terms
Open-Meteo elevation API: https://open-meteo.com/en/docs/elevation-api
Full project notices: https://github.com/batbox55/earth-pro/blob/main/THIRD_PARTY_NOTICES.md
Earth Pro terms: https://zachenson.com/earth-pro/terms

## Provider attribution

Retain these notices and the complete resource attribution files when redistributing:

- [Imagery-Credits.txt](Sources/EarthPro/Resources/Imagery-Credits.txt): NASA Blue Marble, Natural Earth, live imagery and geographic data attribution.
- [Terrain-Attribution.txt](Sources/EarthPro/Resources/Terrain-Attribution.txt): complete upstream Mapzen/AWS Terrain Tiles data notices and component licenses, including attribution requirements.
- Natural Earth vector datasets are public domain: https://www.naturalearthdata.com/about/terms-of-use/
- NASA Blue Marble imagery: NASA/Goddard Space Flight Center Scientific Visualization Studio, https://svs.gsfc.nasa.gov/2915/ . NASA names and insignia are not licensed by this project.
- Live OpenStreetMap content: © OpenStreetMap contributors; database licensed under ODbL, https://www.openstreetmap.org/copyright . Public tile usage is governed by https://operations.osmfoundation.org/policies/tiles/ .
- Wikipedia excerpts are attributed to the linked articles under CC BY-SA 4.0. Wikimedia Commons photos have individual licenses and attribution, shown with each result. No Commons photo collection is bundled here.
- Esri World Imagery and Wayback imagery retain Esri and imagery-contributor terms: https://www.esri.com/en-us/legal/terms/data-attributions . A publicly reachable tile endpoint is not a blanket commercial redistribution license.
- Public parcels, zoning, flood, and utility data and custom connections retain publisher-specific terms. Consult each source metadata/terms link; missing licensing information is not a commercial-use grant.
- Open-Meteo free elevation API is limited to noncommercial use under https://open-meteo.com/en/terms . Its data license and the API service restrictions are separate.
- Apple MapKit, Google Maps/3D, NASA GIBS, USGS, Open-Meteo, and Wikimedia services have separate terms and privacy policies. User-supplied API keys do not transfer map-content ownership or waive service restrictions. Map imagery, screenshots, exports, and recordings must respect provider attribution and reuse rules.
- Swift, SwiftUI, AppKit, SceneKit, MapKit, WebKit, and other Apple frameworks are supplied by their respective toolchains and operating system, not relicensed by this project.

Earth Pro is independently developed and is not affiliated with or endorsed by Google, Apple, NASA, or the other data providers.
