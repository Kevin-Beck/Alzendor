namespace Alzendor.Server.Core.Actions
{
    public class SubscribeAction : ActionObject
    {
        public string Sender { get; set; }
        public string GameElementName { get; set; }
        public SubscriptionType TypeOfSubscription { get; set; }
        public SubscribeAction(string sender, string gameElementName, SubscriptionType type) : base("Subscribe", ActionPriority.LOW, ActionType.SUBSCRIBE)
        {
            Sender = sender;
            GameElementName = gameElementName;
            TypeOfSubscription = type;
        }
    }
}
