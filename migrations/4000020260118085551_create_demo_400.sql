-- +goose Up
CREATE TABLE IF NOT EXISTS demo_400 (
    id   INTEGER PRIMARY KEY,
    note TEXT
);

-- +goose Down
DROP TABLE IF EXISTS demo_400;
