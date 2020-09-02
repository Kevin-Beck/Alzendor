namespace AlzendorCore.Utilities.Actions
{
    public class Action
    {
        public string Name { get; }
        public ActionPriority Priority { get; }
        public ActionType Type { get; }

        public Action(string name, ActionPriority priority, ActionType type)
        {
            Name = name;
            Priority = priority;
            Type = type;
        }
    }
}
