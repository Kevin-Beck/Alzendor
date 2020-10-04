namespace Alzendor.Server.Core.Actions
{
    public class ActionObject
    {
        public string Name { get; }
        public ActionPriority Priority { get; }
        public ActionType Type { get; }

        public ActionObject(string name, ActionPriority priority, ActionType type)
        {
            Name = name;
            Priority = priority;
            Type = type;
        }
    }
}
