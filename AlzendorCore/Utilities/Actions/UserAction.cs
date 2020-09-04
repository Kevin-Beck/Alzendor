namespace AlzendorCore.Utilities.Actions
{
    public class UserAction
    {
        public string Name { get; }
        public ActionPriority Priority { get; }
        public ActionType Type { get; }

        public UserAction(string name, ActionPriority priority, ActionType type)
        {
            Name = name;
            Priority = priority;
            Type = type;
        }
    }
}
