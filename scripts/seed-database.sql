CREATE TABLE IF NOT EXISTS energy_readings (
    id SERIAL PRIMARY KEY,
    client_id VARCHAR(255) NOT NULL,
    meter_id VARCHAR(255) NOT NULL,
    reading_kwh FLOAT NOT NULL,
    recorded_at TIMESTAMP NOT NULL,
    created_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_energy_readings_client_id
    ON energy_readings(client_id);

CREATE TABLE IF NOT EXISTS biomass_readings (
    id SERIAL PRIMARY KEY,
    sensor_id VARCHAR(255) NOT NULL,
    plant_id VARCHAR(255) NOT NULL,
    temperature_celsius FLOAT,
    moisture_percent FLOAT,
    output_kwh FLOAT,
    sensor_timestamp TIMESTAMP NOT NULL,
    created_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_biomass_readings_sensor_id
    ON biomass_readings(sensor_id);

CREATE TABLE IF NOT EXISTS meter_readings (
    id SERIAL PRIMARY KEY,
    client_id VARCHAR(255) NOT NULL,
    meter_id VARCHAR(255) NOT NULL,
    reading_kwh FLOAT NOT NULL,
    recorded_at TIMESTAMP NOT NULL,
    source_file VARCHAR(500),
    created_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_meter_readings_client_id
    ON meter_readings(client_id);

INSERT INTO energy_readings (client_id, meter_id, reading_kwh, recorded_at)
VALUES
    ('client-001', 'meter-A', 142.3, NOW() - INTERVAL '1 day'),
    ('client-001', 'meter-A', 138.7, NOW() - INTERVAL '2 days'),
    ('client-001', 'meter-A', 155.1, NOW() - INTERVAL '3 days'),
    ('client-001', 'meter-B', 89.4,  NOW() - INTERVAL '1 day'),
    ('client-001', 'meter-B', 92.1,  NOW() - INTERVAL '2 days'),
    ('client-002', 'meter-C', 201.8, NOW() - INTERVAL '1 day'),
    ('client-002', 'meter-C', 198.3, NOW() - INTERVAL '2 days');