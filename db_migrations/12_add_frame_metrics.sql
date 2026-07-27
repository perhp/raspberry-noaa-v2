ALTER TABLE predict_passes
ADD COLUMN frames_received integer;

ALTER TABLE predict_passes
ADD COLUMN frames_expected integer;

ALTER TABLE predict_passes
ADD COLUMN frame_loss_pct real;

ALTER TABLE predict_passes
ADD COLUMN largest_frame_gap integer;
