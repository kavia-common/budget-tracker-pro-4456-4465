BEGIN;

INSERT INTO categories (name, type, color) VALUES ('Salary','income','#059669') ON CONFLICT DO NOTHING;
INSERT INTO categories (name, type, color) VALUES ('Bonus','income','#10B981') ON CONFLICT DO NOTHING;
INSERT INTO categories (name, type, color) VALUES ('Rent','expense','#1E3A8A') ON CONFLICT DO NOTHING;
INSERT INTO categories (name, type, color) VALUES ('Utilities','expense','#2563EB') ON CONFLICT DO NOTHING;
INSERT INTO categories (name, type, color) VALUES ('Groceries','expense','#F59E0B') ON CONFLICT DO NOTHING;
INSERT INTO categories (name, type, color) VALUES ('Dining','expense','#F97316') ON CONFLICT DO NOTHING;
INSERT INTO categories (name, type, color) VALUES ('Transport','expense','#0EA5E9') ON CONFLICT DO NOTHING;
INSERT INTO categories (name, type, color) VALUES ('Entertainment','expense','#8B5CF6') ON CONFLICT DO NOTHING;
INSERT INTO categories (name, type, color) VALUES ('Health','expense','#DC2626') ON CONFLICT DO NOTHING;
INSERT INTO categories (name, type, color) VALUES ('Travel','expense','#14B8A6') ON CONFLICT DO NOTHING;
INSERT INTO categories (name, type, color) VALUES ('Other','expense','#6B7280') ON CONFLICT DO NOTHING;

COMMIT;
