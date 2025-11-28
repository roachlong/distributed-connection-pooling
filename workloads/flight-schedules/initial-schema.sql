-- Static tables (rarely change)
CREATE TABLE airlines (
  airline_id   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name         STRING NOT NULL
);

CREATE TABLE airports (
  airport_id     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  airport_code   STRING UNIQUE,
  name           STRING,
  city           STRING,
  country        STRING
);

CREATE TABLE planes (
  plane_id   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  model      STRING,
  capacity   INT
);

-- Flight schedule (mostly static per day)
CREATE TABLE flights (
  flight_id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  airline_id            UUID NOT NULL REFERENCES airlines,
  plane_id              UUID NOT NULL REFERENCES planes,
  departure_airport     UUID NOT NULL REFERENCES airports,
  arrival_airport       UUID NOT NULL REFERENCES airports,
  scheduled_departure   TIMESTAMPTZ NOT NULL,
  scheduled_arrival     TIMESTAMPTZ NOT NULL,
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Dynamic tables (frequently updated)
CREATE TABLE flight_status (
  flight_id   UUID PRIMARY KEY REFERENCES flights,
  status      STRING NOT NULL,  -- e.g. 'on_time','delayed','cancelled'
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE seat_inventory (
  flight_id         UUID PRIMARY KEY REFERENCES flights,
  seats_available   INT NOT NULL,
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE flight_prices (
  flight_id    UUID PRIMARY KEY REFERENCES flights,
  price_usd    DECIMAL NOT NULL,
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
