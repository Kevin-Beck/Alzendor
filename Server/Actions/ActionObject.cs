using Server.Base;
using Server.Database;
using Server.Elements;

namespace Server.Actions
{
    public abstract class ActionObject
    {
        public string Sender { get; }
        public ActionType ActionType { get; }
        public ElementType ElementType { get; }
        public string ElementName { get; }
        public ActionPriority Priority { get; }
        /// <summary>
        /// Action object represents an action performed by something (player, npc, room, etc) on another something (player, npc, room, etc)
        /// </summary>
        /// <param name="sender">The entity performing the object, usually a player entering a command</param>
        /// <param name="action">The ActionType is the Enum that cooresponds to the Action, (A ChangeAction object will have ActionType.CHANGE)</param>
        /// <param name="element">The receiving end of the action, the target element</param>
        /// <param name="elementName">The name of the target GameElement (Player, npc, channel etc)</param>
        /// <param name="priority">The priority of this action (not currently implemented)</param>
        public ActionObject(string sender, ActionType action, ElementType element, string elementName, ActionPriority priority)
        {
            Sender = sender;
            ActionType = action;
            ElementType = element;
            ElementName = elementName;
            Priority = priority;
        }

        public abstract void ExecuteAction(IDatabaseWrapper storage, ConnectionToClient connection);
    }
}
