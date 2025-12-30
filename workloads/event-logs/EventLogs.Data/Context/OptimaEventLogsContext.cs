using System;
using System.Collections.Generic;
using EventLogs.Data;
using Microsoft.EntityFrameworkCore;
using Npgsql.EntityFrameworkCore.PostgreSQL.Metadata;

namespace EventLogs.Data.Context;

public partial class OptimaEventLogsContext : DbContext
{
    private readonly string? _connectionString;

    public OptimaEventLogsContext()
    {
    }

    public OptimaEventLogsContext(DbContextOptions<OptimaEventLogsContext> options)
        : base(options)
    {
    }

    public OptimaEventLogsContext(string connectionString)
    {
        _connectionString = connectionString;
    }

    public virtual DbSet<AccountInfo> AccountInfo { get; set; }

    public virtual DbSet<RequestAccountLink> RequestAccountLink { get; set; }

    public virtual DbSet<RequestActionStateLink> RequestActionStateLink { get; set; }

    public virtual DbSet<RequestActionType> RequestActionType { get; set; }

    public virtual DbSet<RequestEventLog> RequestEventLog { get; set; }

    public virtual DbSet<RequestInfo> RequestInfo { get; set; }

    public virtual DbSet<RequestState> RequestState { get; set; }

    public virtual DbSet<RequestStatus> RequestStatus { get; set; }

    public virtual DbSet<RequestStatusHead> RequestStatusHead { get; set; }

    public virtual DbSet<RequestType> RequestType { get; set; }

    public virtual DbSet<TradeInfo> TradeInfo { get; set; }

    protected override void OnConfiguring(DbContextOptionsBuilder optionsBuilder)
    {
        if (!optionsBuilder.IsConfigured)
        {
            var cs = _connectionString
                     ?? Environment.GetEnvironmentVariable("EVENTLOGS_DB") 
                     ?? throw new InvalidOperationException("EVENTLOGS_DB not configured.");

            optionsBuilder.UseNpgsql(cs, o =>
            {
                // Enable retries for transient CockroachDB/network errors
                o.EnableRetryOnFailure(); 
            });
        }
    }

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        modelBuilder.HasPostgresEnum("crdb_internal_region", new[] { "us-central", "us-east", "us-west" });

        modelBuilder.Entity<AccountInfo>(entity =>
        {
            entity
                .HasNoKey()
                .ToTable("account_info", tb => tb.HasComment("Identifies the minimum selected value."));

            entity.Property(e => e.AccountId)
                .HasDefaultValueSql("gen_random_uuid()")
                .HasColumnName("account_id");
            entity.Property(e => e.AccountName).HasColumnName("account_name");
            entity.Property(e => e.AccountNumber).HasColumnName("account_number");
            entity.Property(e => e.BaseCurrency).HasColumnName("base_currency");
            entity.Property(e => e.Locality)
                .HasComputedColumnSql("mod(crc32ieee(account_id::BYTES), 30)::INT2", true)
                .HasColumnName("locality");
            entity.Property(e => e.Strategy).HasColumnName("strategy");
        });

        modelBuilder.Entity<RequestAccountLink>(entity =>
        {
            entity.HasKey(e => new { e.RequestId, e.AccountId }).HasName("request_account_link_pkey");

            entity.ToTable("request_account_link", tb => tb.HasComment("Concatenates all selected values using the provided delimiter."));

            entity.Property(e => e.RequestId).HasColumnName("request_id");
            entity.Property(e => e.AccountId).HasColumnName("account_id");
            entity.Property(e => e.AllocationPct)
                .HasPrecision(5, 2)
                .HasColumnName("allocation_pct");
            entity.Property(e => e.Role).HasColumnName("role");
        });

        modelBuilder.Entity<RequestActionStateLink>(entity =>
        {
            entity.HasKey(e => e.ActionStateLinkId).HasName("request_action_state_link_pkey");

            entity.ToTable("request_action_state_link", tb => tb.HasComment("Identifies the minimum selected value."));

            entity.HasIndex(e => new { e.RequestTypeId, e.ActionTypeId, e.SortOrder }, "idx_rasl_by_request_action")
                .HasMethod("prefix")
                .HasNullSortOrder(new[] { NullSortOrder.NullsFirst, NullSortOrder.NullsFirst, NullSortOrder.NullsFirst });

            entity.HasIndex(e => new { e.RequestTypeId, e.ActionTypeId, e.StateId }, "request_action_state_link_request_type_id_action_type_id_state_id_key").IsUnique();

            entity.Property(e => e.ActionStateLinkId)
                .HasDefaultValueSql("unique_rowid()")
                .HasColumnName("action_state_link_id");
            entity.Property(e => e.ActionTypeId).HasColumnName("action_type_id");
            entity.Property(e => e.IsInitial)
                .HasDefaultValue(false)
                .HasColumnName("is_initial");
            entity.Property(e => e.IsTerminal)
                .HasDefaultValue(false)
                .HasColumnName("is_terminal");
            entity.Property(e => e.RequestTypeId).HasColumnName("request_type_id");
            entity.Property(e => e.SortOrder)
                .HasDefaultValue(0)
                .HasColumnName("sort_order");
            entity.Property(e => e.StateId).HasColumnName("state_id");

            entity.HasOne(d => d.ActionType).WithMany(p => p.RequestActionStateLink)
                .HasForeignKey(d => d.ActionTypeId)
                .OnDelete(DeleteBehavior.ClientSetNull)
                .HasConstraintName("request_action_state_link_action_type_id_fkey");

            entity.HasOne(d => d.RequestType).WithMany(p => p.RequestActionStateLink)
                .HasForeignKey(d => d.RequestTypeId)
                .OnDelete(DeleteBehavior.ClientSetNull)
                .HasConstraintName("request_action_state_link_request_type_id_fkey");

            entity.HasOne(d => d.State).WithMany(p => p.RequestActionStateLink)
                .HasForeignKey(d => d.StateId)
                .OnDelete(DeleteBehavior.ClientSetNull)
                .HasConstraintName("request_action_state_link_state_id_fkey");
        });

        modelBuilder.Entity<RequestActionType>(entity =>
        {
            entity.HasKey(e => e.ActionTypeId).HasName("request_action_type_pkey");

            entity.ToTable("request_action_type", tb => tb.HasComment("Identifies the minimum selected value."));

            entity.HasIndex(e => e.ActionCode, "request_action_type_action_code_key").IsUnique();

            entity.Property(e => e.ActionTypeId)
                .ValueGeneratedNever()
                .HasColumnName("action_type_id");
            entity.Property(e => e.ActionCode).HasColumnName("action_code");
            entity.Property(e => e.Description).HasColumnName("description");
        });

        modelBuilder.Entity<RequestEventLog>(entity =>
        {
            entity
                .HasNoKey()
                .ToTable("request_event_log", tb => tb.HasComment("Calculates the sum of the selected values."));

            entity.Property(e => e.ActionStateLinkId).HasColumnName("action_state_link_id");
            entity.Property(e => e.Actor).HasColumnName("actor");
            entity.Property(e => e.EventTs)
                .HasDefaultValueSql("now()")
                .HasColumnName("event_ts");
            entity.Property(e => e.IdempotencyKey).HasColumnName("idempotency_key");
            entity.Property(e => e.Locality).HasColumnName("locality");
            entity.Property(e => e.Metadata)
                .HasColumnType("jsonb")
                .HasColumnName("metadata");
            entity.Property(e => e.RequestId).HasColumnName("request_id");
            entity.Property(e => e.SeqNum).HasColumnName("seq_num");
            entity.Property(e => e.StatusId).HasColumnName("status_id");

            entity.HasOne(d => d.ActionStateLink).WithMany()
                .HasForeignKey(d => d.ActionStateLinkId)
                .OnDelete(DeleteBehavior.ClientSetNull)
                .HasConstraintName("request_event_log_action_state_link_id_fkey");

            entity.HasOne(d => d.Status).WithMany()
                .HasForeignKey(d => d.StatusId)
                .OnDelete(DeleteBehavior.ClientSetNull)
                .HasConstraintName("request_event_log_status_id_fkey");
        });

        modelBuilder.Entity<RequestInfo>(entity =>
        {
            entity
                .HasNoKey()
                .ToTable("request_info", tb => tb.HasComment("Concatenates all selected values using the provided delimiter."));

            entity.Property(e => e.CreatedTs)
                .HasDefaultValueSql("now()")
                .HasColumnName("created_ts");
            entity.Property(e => e.Description).HasColumnName("description");
            entity.Property(e => e.Locality).HasColumnName("locality");
            entity.Property(e => e.PrimaryAccountId).HasColumnName("primary_account_id");
            entity.Property(e => e.RequestId)
                .HasDefaultValueSql("gen_random_uuid()")
                .HasColumnName("request_id");
            entity.Property(e => e.RequestStatusId).HasColumnName("request_status_id");
            entity.Property(e => e.RequestTypeId).HasColumnName("request_type_id");
            entity.Property(e => e.RequestedBy).HasColumnName("requested_by");
            entity.Property(e => e.TargetEffectiveTs).HasColumnName("target_effective_ts");

            entity.HasOne(d => d.RequestStatus).WithMany()
                .HasForeignKey(d => d.RequestStatusId)
                .OnDelete(DeleteBehavior.ClientSetNull)
                .HasConstraintName("request_info_request_status_id_fkey");

            entity.HasOne(d => d.RequestType).WithMany()
                .HasForeignKey(d => d.RequestTypeId)
                .OnDelete(DeleteBehavior.ClientSetNull)
                .HasConstraintName("request_info_request_type_id_fkey");
        });

        modelBuilder.Entity<RequestState>(entity =>
        {
            entity.HasKey(e => e.StateId).HasName("request_state_pkey");

            entity.ToTable("request_state", tb => tb.HasComment("Identifies the minimum selected value."));

            entity.HasIndex(e => e.StateCode, "request_state_state_code_key").IsUnique();

            entity.Property(e => e.StateId)
                .ValueGeneratedNever()
                .HasColumnName("state_id");
            entity.Property(e => e.Description).HasColumnName("description");
            entity.Property(e => e.StateCode).HasColumnName("state_code");
        });

        modelBuilder.Entity<RequestStatus>(entity =>
        {
            entity.HasKey(e => e.StatusId).HasName("request_status_pkey");

            entity.ToTable("request_status", tb => tb.HasComment("Identifies the minimum selected value."));

            entity.HasIndex(e => e.StatusCode, "request_status_status_code_key").IsUnique();

            entity.Property(e => e.StatusId)
                .ValueGeneratedNever()
                .HasColumnName("status_id");
            entity.Property(e => e.Description).HasColumnName("description");
            entity.Property(e => e.StatusCode).HasColumnName("status_code");
        });

        modelBuilder.Entity<RequestStatusHead>(entity =>
        {
            entity
                .HasNoKey()
                .ToTable("request_status_head", tb => tb.HasComment("Calculates the sum of the selected values."));

            entity.Property(e => e.ActionStateLinkId).HasColumnName("action_state_link_id");
            entity.Property(e => e.EventTs).HasColumnName("event_ts");
            entity.Property(e => e.Locality).HasColumnName("locality");
            entity.Property(e => e.RequestId).HasColumnName("request_id");
            entity.Property(e => e.SeqNum).HasColumnName("seq_num");
            entity.Property(e => e.StatusId).HasColumnName("status_id");

            entity.HasOne(d => d.ActionStateLink).WithMany()
                .HasForeignKey(d => d.ActionStateLinkId)
                .OnDelete(DeleteBehavior.ClientSetNull)
                .HasConstraintName("request_status_head_action_state_link_id_fkey");

            entity.HasOne(d => d.Status).WithMany()
                .HasForeignKey(d => d.StatusId)
                .OnDelete(DeleteBehavior.ClientSetNull)
                .HasConstraintName("request_status_head_status_id_fkey");
        });

        modelBuilder.Entity<RequestType>(entity =>
        {
            entity.HasKey(e => e.RequestTypeId).HasName("request_type_pkey");

            entity.ToTable("request_type", tb => tb.HasComment("Identifies the minimum selected value."));

            entity.HasIndex(e => e.RequestTypeCode, "request_type_request_type_code_key").IsUnique();

            entity.Property(e => e.RequestTypeId)
                .ValueGeneratedNever()
                .HasColumnName("request_type_id");
            entity.Property(e => e.Description).HasColumnName("description");
            entity.Property(e => e.RequestTypeCode).HasColumnName("request_type_code");
        });

        modelBuilder.Entity<TradeInfo>(entity =>
        {
            entity
                .HasNoKey()
                .ToTable("trade_info", tb => tb.HasComment("Calculates the sum of the selected values."));

            entity.Property(e => e.AccountId).HasColumnName("account_id");
            entity.Property(e => e.CreatedTs)
                .HasDefaultValueSql("now()")
                .HasColumnName("created_ts");
            entity.Property(e => e.Currency).HasColumnName("currency");
            entity.Property(e => e.Locality).HasColumnName("locality");
            entity.Property(e => e.Price)
                .HasPrecision(20, 4)
                .HasColumnName("price");
            entity.Property(e => e.Quantity)
                .HasPrecision(20, 4)
                .HasColumnName("quantity");
            entity.Property(e => e.RequestId).HasColumnName("request_id");
            entity.Property(e => e.Side).HasColumnName("side");
            entity.Property(e => e.StatusId).HasColumnName("status_id");
            entity.Property(e => e.Symbol).HasColumnName("symbol");
            entity.Property(e => e.TradeId)
                .HasDefaultValueSql("gen_random_uuid()")
                .HasColumnName("trade_id");
            entity.Property(e => e.UpdatedTs).HasColumnName("updated_ts");

            entity.HasOne(d => d.Status).WithMany()
                .HasForeignKey(d => d.StatusId)
                .OnDelete(DeleteBehavior.ClientSetNull)
                .HasConstraintName("trade_info_status_id_fkey");
        });

        OnModelCreatingPartial(modelBuilder);
    }

    partial void OnModelCreatingPartial(ModelBuilder modelBuilder);
}
