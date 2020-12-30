using Server.Elements;

namespace Server.Actions
{
    public class CreateAction : ActionObject
    {
        public CreateAction(string sender, ElementType typeOfElement, string nameOfObject) : base(sender, ActionType.CREATE, typeOfElement, nameOfObject, ActionPriority.LOW)
        {

        }
    }
}
