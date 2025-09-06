# CloudBeaver Initial Setup

CloudBeaver requires a one-time setup to configure the administrator account and prepare it for database connections.

## Automatic Setup (Recommended)

When you first visit http://localhost:8080, you'll see the CloudBeaver setup wizard. Follow these steps:

### Step 1: Welcome
- Click **Next** on the welcome screen

### Step 2: Server Configuration
Fill in the administrator credentials:
- **Login**: `cbadmin`
- **Password**: `CloudBeaver1` (meets password requirements: mixed case + number)
- **Repeat Password**: `CloudBeaver1`

Make sure to **disable anonymous access** (uncheck the "Allow anonymous access" option) for security.

Keep all other settings as default, then click **Next**.

### Step 3: Confirmation
- Click **Finish** to complete the setup

## After Setup

Once setup is complete, you can:

1. **Login** with the credentials:
   - Username: `cbadmin`
   - Password: `CloudBeaver1`

2. **Connect to PostgreSQL** by creating a new connection:
   - Click "Create a new connection" or "New Connection"
   - Select **PostgreSQL** from the database drivers
   - Fill in the connection details:
     - **Host**: `postgres` (the container name)
     - **Port**: `5432`
     - **Database**: `postgres` (or any database name)
     - **Username**: Use the `POSTGRES_USER` from your `.env` file
     - **Password**: Use the `POSTGRES_PASSWORD` from your `.env` file
   - Click **Test** to verify the connection
   - Click **Create** to save the connection

The PostgreSQL container is accessible from CloudBeaver via the hostname `postgres` since they're on the same Docker network.

## Screenshot

![CloudBeaver with PostgreSQL Connection](https://github.com/user-attachments/assets/5f45b98b-a46d-43c9-a84e-c40e9f7fc3b0)

The screenshot shows CloudBeaver successfully configured with:
- Administrator logged in (cbadmin)
- PostgreSQL connection ready in the sidebar
- Full database management interface available