-- 5 airlines
INSERT INTO airlines (name)
SELECT 'Airline_' || i
FROM generate_series(1,5) AS g(i);

-- 20 airports
WITH codes AS (
  SELECT
    chr(65 + i1)::STRING ||
    chr(65 + i2)::STRING ||
    chr(65 + i3)::STRING AS airport_code
  FROM generate_series(0,25) AS g1(i1),
       generate_series(0,25) AS g2(i2),
       generate_series(0,25) AS g3(i3)
),
selected AS (
  SELECT airport_code
  FROM codes
  ORDER BY random()
  LIMIT 20
)
INSERT INTO airports (airport_code, name, city, country)
SELECT
  airport_code,
  'Airport ' || row_number() OVER() AS name,
  'City_' || ((row_number() OVER() - 1) % 20 + 1) AS city,
  'Country_' || ((row_number() OVER() - 1) % 1 + 1) AS country
FROM selected;

-- 500 planes
WITH models(model, capacity) AS (
  SELECT
    'Model_' || floor(random()*10)::INT,
    (100 + floor(random()*200)::INT)
  FROM generate_series(1,10) AS m(i)
)
INSERT INTO planes (model,capacity)
SELECT model, capacity
FROM models,
     (SELECT i FROM generate_series(1,50) AS p(i));

-- 1MM flights over next 7 days
INSERT INTO flights (
  airline_id, plane_id, departure_airport, arrival_airport,
  scheduled_departure, scheduled_arrival
)
SELECT
  al.airline_id,
  p.plane_id,
  da.airport_id,
  aa.airport_id,
  now() + ((random() * 7 * 24 * 60 * 60)::INT * interval '1 second'),
  now() + (((random() * 7 * 24 * 60 * 60)::INT + 2 * 60 * 60) * interval '1 second')
FROM (SELECT airline_id FROM airlines ORDER BY random()) AS al,
     (SELECT airport_id FROM airports ORDER BY random()) AS da,
     (SELECT airport_id FROM airports ORDER BY random()) AS aa,
     (SELECT plane_id FROM planes ORDER BY random()) AS p;

-- Initialize dynamic tables with defaults
INSERT INTO flight_status (flight_id, status)
SELECT flight_id, 'on_time' FROM flights;

INSERT INTO seat_inventory (flight_id, seats_available)
SELECT flight_id, (capacity / 2)::INT FROM flights JOIN planes USING(plane_id);

INSERT INTO flight_prices (flight_id, price_usd)
SELECT flight_id, (50 + random()*450)::DECIMAL(10,2) FROM flights;
