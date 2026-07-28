CREATE TABLE "builders" (
	"id" text PRIMARY KEY NOT NULL,
	"handle" text NOT NULL,
	"display_name" text NOT NULL,
	"avatar_url" text,
	"team" text,
	"agent" text DEFAULT 'claude' NOT NULL,
	"visibility" text DEFAULT 'public' NOT NULL,
	"token_hash" text NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"published_at" timestamp with time zone,
	CONSTRAINT "builders_handle_unique" UNIQUE("handle")
);
--> statement-breakpoint
CREATE TABLE "usage_days" (
	"builder_id" text NOT NULL,
	"day" date NOT NULL,
	"model" text NOT NULL,
	"input_tokens" bigint DEFAULT 0 NOT NULL,
	"output_tokens" bigint DEFAULT 0 NOT NULL,
	"cache_read_tokens" bigint DEFAULT 0 NOT NULL,
	"cache_write_tokens" bigint DEFAULT 0 NOT NULL,
	"cost_usd" double precision DEFAULT 0 NOT NULL,
	"focus_seconds" integer DEFAULT 0 NOT NULL,
	"sessions" integer DEFAULT 0 NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "usage_days_builder_id_day_model_pk" PRIMARY KEY("builder_id","day","model")
);
--> statement-breakpoint
ALTER TABLE "usage_days" ADD CONSTRAINT "usage_days_builder_id_builders_id_fk" FOREIGN KEY ("builder_id") REFERENCES "public"."builders"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "usage_days_day_idx" ON "usage_days" USING btree ("day");