# Venstar Thermostat Driver for Control4 (Local API)

An open-source Control4 DriverWorks driver for Venstar Wi-Fi thermostats. It uses the Control4 **thermostatV2** proxy and talks to the thermostat directly over the **Venstar Local API**, so no cloud account or internet connection is needed.

Supports Venstar ColorTouch, Explorer and commercial thermostats that have the Local API.

## Features

- **Full thermostat control from Navigator:** HVAC mode (Off / Heat / Cool / Auto, limited to the modes the thermostat offers), heat and cool setpoints, and fan mode (Auto / On).
- **Hold modes:**
  - **Off:** the thermostat runs its own schedule.
  - **Permanent:** the schedule is off and the current setpoints are held.
  - **Away:** residential thermostats only.
- **Humidity:** current indoor humidity, plus optional humidify and dehumidify setpoints.
- **Outdoor temperature** when the thermostat has an outdoor sensor.
- **Navigator Extras tab** with read-only sections for Sensors (every sensor the thermostat reports), Status and Alerts.
- **Sensor outputs** for indoor temperature, indoor humidity and outdoor temperature, which can be bound to other drivers.
- **Programming:**
  - Events for air filter, UV lamp and service alerts, Away on/off, and communication lost/restored.
  - Commands for Away, schedule, and humidify/dehumidify setpoints.
  - Variables for state, setpoints and alerts.
- **Security:** HTTP or HTTPS, HTTP Digest authentication, and the screen-lock PIN.
- **Self-contained:** a single `driver.lua` with no external libraries; JSON parsing and Digest authentication are built in.

## Venstar API behavior the driver accounts for

- Setpoint changes and mode changes are sent as separate `/control` requests.
  - The API accepts only fan alone, setpoints alone, or mode with both setpoints.
- The cool setpoint is kept at least `setpointdelta` above the heat setpoint.
  - Raising heat pushes cool up; lowering cool pushes heat down.
- Away cannot be set while the schedule is running, and the schedule cannot be resumed while Away is on, so the driver sends those changes in the required order.
- The thermostat does not handle concurrent requests, so every request goes through one queue.
- Quick taps on the setpoint arrows within 0.7 s are combined into a single request.
- T2xxx/T3xxx thermostats on firmware older than 5.28 report Celsius regardless of the display units. The driver detects this from the model and firmware.
- On API v5 (T5900, firmware 4.08) the humidity setpoint fields are swapped. The driver reads them correctly and does not write them.

## Installation

1. On the thermostat, enable the **Local API** in its Wi-Fi settings.
2. Give the thermostat a DHCP reservation so its IP address does not change.
3. Download `Venstar_Thermostat.c4z` from Releases and add it to your project in Composer Pro.
4. In the driver properties:
   - Enter the **IP Address**.
   - If Local API authentication is enabled, set **Use HTTPS** to Yes and enter the **Username** and **Password**.
   - If Screen Lock is enabled, enter the **Screen Lock PIN**.
5. Run the **Test Connection** action and confirm **Driver Status** shows *Online*.
6. Refresh Navigator so it loads the Extras tab.

## Properties

| Property | Description |
|---|---|
| IP Address | Thermostat IP address |
| Use HTTPS | Use HTTPS (required when Local API authentication is on) |
| Username / Password | Local API credentials (masked) |
| Screen Lock PIN | Needed when Screen Lock is enabled (masked) |
| Poll Interval (seconds) | 10–300, default 30 |
| Humidity Control | Off / Humidify / Dehumidify / Humidify and Dehumidify |
| Outdoor Temperature | Auto (show it when an outdoor sensor exists) / Disabled |
| Debug Mode / Debug Level | Logging; Debug Mode turns itself off after 6 hours |

The read-only properties show the model, firmware, API version, current activity and stage, schedule, Away or occupancy, sensors, alerts and the time of the last update.

## Repository layout

```
driver.xml               Driver definition: proxy, capabilities, connections, properties, events, commands
driver.lua               Driver logic
www/documentation.html   Documentation shown in Composer
test_harness.lua         Offline test harness: mock Control4 runtime + simulated Venstar thermostat
```

## Building

The .c4z is a flat zip with `driver.xml` and `driver.lua` at the root:

```sh
zip -X Venstar_Thermostat.c4z driver.xml driver.lua www/documentation.html
```

## Testing

The harness simulates Control4 and a Venstar thermostat. The simulated thermostat enforces the API rules listed above, including Digest authentication and the PIN.

```sh
texluac -p driver.lua
texlua test_harness.lua driver.lua
```

## Sources

The driver was built from these references:

1. **Venstar Local API documentation:** <https://developer.venstar.com/documentation/>
   - Endpoints, fields, `/control` and `/settings` request rules, PIN requirements and SSDP discovery.
2. **Home Assistant Venstar integration documentation:** <https://www.home-assistant.io/integrations/venstar/>
   - Supported features, configuration options and user-facing behavior.
3. **Home Assistant Venstar integration source:** <https://github.com/home-assistant/core/tree/dev/homeassistant/components/venstar>
   - Mode, hold and Away mapping, setpoint handling and the timing between requests.

Also consulted:

- [`venstarcolortouch`](https://pypi.org/project/venstarcolortouch/), the Python library used by the Home Assistant integration. Source of the request-combination rules, the firmware-specific units quirk, the API v5 humidity field swap and the Digest authentication approach.
- [`finitelabs/control4-esphome`](https://github.com/finitelabs/control4-esphome), a working thermostatV2 driver. Used as the reference for proxy notification names and dynamic capabilities.

## Disclaimer

This is an independent, community project. It is not affiliated with or endorsed by Venstar, Snap One / Control4, or Home Assistant. All trademarks belong to their owners.

## License

Open source. See [LICENSE](LICENSE).
