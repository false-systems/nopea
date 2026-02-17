# Define Mox mocks
Mox.defmock(Nopea.K8sMock, for: Nopea.K8s.Behaviour)

# Route K8s calls through mock in tests
Application.put_env(:nopea, :k8s_module, Nopea.K8sMock)

# Set up a dummy K8s.Conn for tests (config can't create structs)
Application.put_env(:nopea, :k8s_conn, %K8s.Conn{})

ExUnit.start(exclude: [:integration, :cluster])
